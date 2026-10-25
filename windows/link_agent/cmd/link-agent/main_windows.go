//go:build windows

package main

import (
	"context"
	"errors"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"strings"
	"time"
	"unsafe"

	"golang.org/x/sys/windows"
	"golang.org/x/sys/windows/registry"
	"golang.org/x/sys/windows/svc"
	linkagent "ligament-apps/windows/link_agent"
)

const (
	serviceName       = "LigamentLinkAgent"
	serviceRegistry   = `SOFTWARE\Ligament\2FA`
	windowsVersionKey = `SOFTWARE\Microsoft\Windows NT\CurrentVersion`
	stopWaitLimit     = 15 * time.Second
)

var agentVersion = "1.1.119"

func main() {
	isService, err := svc.IsWindowsService()
	if err != nil {
		log.Fatalf("link agent: detect service context: %v", err)
	}
	if !isService {
		log.Fatalf("link agent: %s must be started by the Windows Service Control Manager", serviceName)
	}
	if err := svc.Run(serviceName, &agentService{}); err != nil {
		log.Fatalf("link agent: service dispatcher failed: %v", err)
	}
}

type agentService struct{}

type serviceWorkerResult struct {
	kind string
	err  error
}

func (*agentService) Execute(_ []string, requests <-chan svc.ChangeRequest, statuses chan<- svc.Status) (bool, uint32) {
	statuses <- svc.Status{State: svc.StartPending, WaitHint: uint32(15 * time.Second / time.Millisecond)}

	config, err := readServiceConfig()
	if err != nil {
		log.Printf("link agent: read service configuration: %v", err)
		return false, 1
	}
	_, identityErr := linkagent.LoadIdentity()
	if identityErr != nil && !errors.Is(identityErr, os.ErrNotExist) {
		log.Printf("link agent: load protected identity: %v", identityErr)
		return false, 1
	}
	if identityErr == nil {
		if err := linkagent.ValidateAgentWSMetadata(config); err != nil {
			log.Printf("link agent: invalid service configuration: %v", err)
			return false, 1
		}
	} else if err := linkagent.ValidateAgentHostMetadata(config); err != nil {
		log.Printf("link agent: invalid host metadata: %v", err)
		return false, 1
	}
	logger, closeLog, logErr := openServiceLog()
	if logErr == nil {
		defer closeLog()
	}

	ctx, cancel := context.WithCancel(context.Background())
	config.DeleteIdentity = linkagent.DeleteAgentIdentity
	defer cancel()
	workerBroker := linkagent.NewSessionWorkerBroker(linkagent.NewNativeSessionWorkerLauncher())
	linkagent.SetWorkerLogger(func(format string, args ...any) {
		serviceLog(logger, logErr, "[WORKER] "+format, args...)
	})
	config.OnConnected = workerBroker.RebindSender
	workerResults := make(chan serviceWorkerResult, 2)
	activeWorkers := 0
	startRuntime := func() {
		activeWorkers++
		go func() {
			err := linkagent.RunStoredAgent(ctx, config, linkagent.LoadIdentity, nil, workerBroker.Handler, func(err error) {
				serviceLog(logger, logErr, "WSS connection: %v", err)
			})
			workerResults <- serviceWorkerResult{kind: "runtime", err: err}
		}()
	}
	startBinding := func() {
		activeWorkers++
		go func() {
			err := linkagent.ServeOneBindingPipe(ctx, func(bindCtx context.Context, request linkagent.BindingRequest) (string, error) {
				serverURL, err := configureBindingServerURL(config.ServerURL, request.ServerURL)
				if err != nil {
					if errors.Is(err, linkagent.ErrBindingServerMismatch) {
						return "", &linkagent.BindingPublicError{Code: "server_mismatch", Err: err}
					}
					return "", &linkagent.BindingPublicError{Code: "identity_store_failed", Err: err}
				}
				config.ServerURL = serverURL
				fingerprint, err := linkagent.EnrollAndStoreIdentity(bindCtx, config, request.EnrollmentToken)
				if err != nil {
					serviceLog(logger, logErr, "L1 binding attempt rejected: %v", err)
					code := "enrollment_rejected"
					if errors.Is(err, linkagent.ErrHostAlreadyEnrolled) {
						code = "host_already_enrolled"
					} else if strings.Contains(err.Error(), "persist enrolled identity") {
						code = "identity_store_failed"
					}
					return "", &linkagent.BindingPublicError{Code: code, Err: err}
				}
				serviceLog(logger, logErr, "L1 binding completed: fingerprint=%s", fingerprint)
				return fingerprint, nil
			}, func(err error) {
				serviceLog(logger, logErr, "L1 binding pipe: %v", err)
			})
			workerResults <- serviceWorkerResult{kind: "binding", err: err}
		}()
	}
	if identityErr == nil {
		startRuntime()
	} else {
		startBinding()
	}
	statuses <- svc.Status{
		State:   svc.Running,
		Accepts: svc.AcceptStop | svc.AcceptShutdown | svc.AcceptSessionChange,
	}

	for {
		select {
		case result := <-workerResults:
			activeWorkers--
			if result.kind == "runtime" {
				if errors.Is(result.err, linkagent.ErrAgentUnbound) {
					serviceLog(logger, logErr, "archived identity removed; waiting for local enrollment")
					startBinding()
					continue
				}
				cancel()
				if errors.Is(result.err, context.Canceled) {
					return false, 0
				}
				serviceLog(logger, logErr, "agent runtime stopped: %v", result.err)
				return false, 1
			}
			if result.err != nil {
				cancel()
				if errors.Is(result.err, context.Canceled) {
					return false, 0
				}
				serviceLog(logger, logErr, "L1 binding pipe stopped: %v", result.err)
				return false, 1
			}
			startRuntime()
		case request, ok := <-requests:
			if !ok {
				cancel()
				return false, waitForWorkers(workerResults, activeWorkers, stopWaitLimit, logger, logErr)
			}
			switch request.Cmd {
			case svc.Interrogate:
				statuses <- request.CurrentStatus
			case svc.SessionChange:
				changeName := linkagent.SessionChangeName(request.EventType)
				if request.EventData == 0 {
					serviceLog(logger, logErr, "WTS event=%s session_id=unavailable (missing event data)", changeName)
					continue
				}
				notification := (*windows.WTSSESSION_NOTIFICATION)(uintptrToPointer(request.EventData))
				if notification.Size < uint32(unsafe.Sizeof(windows.WTSSESSION_NOTIFICATION{})) {
					serviceLog(logger, logErr, "WTS event=%s session_id=unavailable (invalid event data size)", changeName)
					continue
				}
				activeConsole := linkagent.GetActiveConsoleSessionID()
				serviceLog(logger, logErr, "WTS event=%s notification_session_id=%d active_console_session_id=%d",
					changeName, notification.SessionID, activeConsole)
			case svc.Stop, svc.Shutdown:
				statuses <- svc.Status{State: svc.StopPending, WaitHint: uint32(stopWaitLimit / time.Millisecond)}
				cancel()
				return false, waitForWorkers(workerResults, activeWorkers, stopWaitLimit, logger, logErr)
			}
		}
	}
}

func waitForWorkers(results <-chan serviceWorkerResult, active int, timeout time.Duration, logger *log.Logger, logErr error) uint32 {
	timer := time.NewTimer(timeout)
	defer timer.Stop()
	for active > 0 {
		select {
		case result := <-results:
			active--
			if result.err != nil && !errors.Is(result.err, context.Canceled) {
				serviceLog(logger, logErr, "%s shutdown: %v", result.kind, result.err)
			}
		case <-timer.C:
			serviceLog(logger, logErr, "service shutdown exceeded %s", timeout)
			return 1
		}
	}
	return 0
}

func readServiceConfig() (linkagent.AgentWSConfig, error) {
	key, err := registry.OpenKey(registry.LOCAL_MACHINE, serviceRegistry, registry.QUERY_VALUE|registry.WOW64_64KEY)
	if err != nil {
		if !errors.Is(err, registry.ErrNotExist) {
			return linkagent.AgentWSConfig{}, fmt.Errorf("open HKLM\\%s: %w", serviceRegistry, err)
		}
	}
	var serverURL string
	if err == nil {
		serverURL, _, err = key.GetStringValue("ServerURL")
		_ = key.Close()
		if err != nil && !errors.Is(err, registry.ErrNotExist) {
			return linkagent.AgentWSConfig{}, fmt.Errorf("read ServerURL from HKLM\\%s: %w", serviceRegistry, err)
		}
	}

	hostname, err := os.Hostname()
	if err != nil || strings.TrimSpace(hostname) == "" {
		return linkagent.AgentWSConfig{}, errors.New("resolve host name")
	}
	osVersion := readWindowsVersion()
	config := linkagent.StoredAgentConfig(serverURL, hostname, osVersion, agentVersion, map[string]any{
		"windows_service": true,
		"session0":        true,
	})
	config.InteractiveUser = linkagent.CurrentInteractiveUser
	config.LocalIPs = linkagent.CurrentLocalIPs
	return config, nil
}

func configureBindingServerURL(configuredURL, requestedURL string) (string, error) {
	serverURL, persist, err := linkagent.ResolveBindingServerURL(configuredURL, requestedURL)
	if err != nil {
		return "", err
	}
	if !persist {
		return serverURL, nil
	}

	key, _, err := registry.CreateKey(registry.LOCAL_MACHINE, serviceRegistry,
		registry.SET_VALUE|registry.WOW64_64KEY)
	if err != nil {
		return "", fmt.Errorf("open HKLM\\%s for ServerURL: %w", serviceRegistry, err)
	}
	defer key.Close()
	if err := key.SetStringValue("ServerURL", serverURL); err != nil {
		return "", fmt.Errorf("save ServerURL to HKLM\\%s: %w", serviceRegistry, err)
	}
	return serverURL, nil
}

func readWindowsVersion() string {
	key, err := registry.OpenKey(registry.LOCAL_MACHINE, windowsVersionKey, registry.QUERY_VALUE|registry.WOW64_64KEY)
	if err != nil {
		return ""
	}
	defer key.Close()
	product, _, _ := key.GetStringValue("ProductName")
	build, _, _ := key.GetStringValue("CurrentBuildNumber")
	if product == "" {
		return build
	}
	if build == "" {
		return product
	}
	return product + " (build " + build + ")"
}

func openServiceLog() (*log.Logger, func(), error) {
	identityPath, err := linkagent.DefaultIdentityStorePath()
	if err != nil {
		return nil, func() {}, err
	}
	file, err := os.OpenFile(filepath.Join(filepath.Dir(identityPath), "agent.log"), os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0600)
	if err != nil {
		return nil, func() {}, err
	}
	return log.New(file, "link-agent ", log.LstdFlags|log.LUTC), func() { _ = file.Close() }, nil
}

func serviceLog(logger *log.Logger, logErr error, format string, args ...any) {
	if logger != nil {
		logger.Printf(format, args...)
		return
	}
	log.Printf("link agent (file log unavailable: %v): "+format, append([]any{logErr}, args...)...)
}

//go:nosplit
func uintptrToPointer(p uintptr) unsafe.Pointer {
	return *(*unsafe.Pointer)(unsafe.Pointer(&p))
}

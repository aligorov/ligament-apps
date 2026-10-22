//go:build darwin || linux

package main

import (
	"bytes"
	"context"
	"errors"
	"log"
	"os"
	"os/exec"
	"os/signal"
	"runtime"
	"strings"
	"syscall"

	linkagent "ligament-apps/windows/link_agent"
)

var unixAgentVersion = "1.1.83"

func readUnixOSVersion() string {
	if runtime.GOOS == "darwin" {
		out, err := exec.Command("sw_vers", "-productVersion").Output()
		if err == nil && len(bytes.TrimSpace(out)) > 0 {
			return string(bytes.TrimSpace(out))
		}
	} else if runtime.GOOS == "linux" {
		data, err := os.ReadFile("/etc/os-release")
		if err == nil {
			for _, line := range strings.Split(string(data), "\n") {
				if strings.HasPrefix(line, "PRETTY_NAME=") {
					return strings.Trim(strings.TrimPrefix(line, "PRETTY_NAME="), "\"")
				}
			}
		}
	}
	return ""
}

func readUnixHardwareModel() string {
	if runtime.GOOS == "darwin" {
		out, err := exec.Command("sysctl", "-n", "hw.model").Output()
		if err == nil && len(bytes.TrimSpace(out)) > 0 {
			return string(bytes.TrimSpace(out))
		}
	} else if runtime.GOOS == "linux" {
		data, err := os.ReadFile("/sys/devices/virtual/dmi/id/product_name")
		if err == nil && len(bytes.TrimSpace(data)) > 0 {
			return string(bytes.TrimSpace(data))
		}
	}
	return ""
}

func main() {
	log.SetFlags(log.LstdFlags | log.LUTC)
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	for {
		err := runUnixAgent(ctx)
		if errors.Is(err, linkagent.ErrAgentUnbound) {
			log.Print("Link identity archived; waiting for a new local enrollment")
			continue
		}
		if err != nil && !errors.Is(err, context.Canceled) {
			log.Printf("link agent stopped: %v", err)
			os.Exit(1)
		}
		return
	}
}

func runUnixAgent(ctx context.Context) error {
	hostname, err := os.Hostname()
	if err != nil || strings.TrimSpace(hostname) == "" {
		return errors.New("link agent: could not resolve host name")
	}
	osFamily := runtime.GOOS
	if osFamily == "darwin" {
		osFamily = "macos"
	}
	osVersion := readUnixOSVersion()
	hwModel := readUnixHardwareModel()
	capabilities := map[string]any{
		"interactive_session_worker": true,
	}
	if hwModel != "" {
		capabilities["hw_model"] = hwModel
	}
	config := linkagent.AgentConfig("", hostname, osFamily, osVersion, unixAgentVersion, capabilities)
	config.InteractiveUser = linkagent.CurrentInteractiveUser
	config.LocalIPs = linkagent.CurrentLocalIPs
	config.DeleteIdentity = linkagent.DeleteAgentIdentity
	if err := linkagent.ValidateAgentHostMetadata(config); err != nil {
		return err
	}

	identity, pinnedServerURL, err := linkagent.LoadAgentIdentity()
	switch {
	case err == nil:
		linkagent.ClearIdentity(identity)
		config.ServerURL = pinnedServerURL
		if err := linkagent.ValidateAgentWSMetadata(config); err != nil {
			return err
		}
	case errors.Is(err, os.ErrNotExist):
		log.Print("link agent awaiting one-time enrollment from Ligament Authenticator")
		if err := linkagent.ServeOneBindingUnix(ctx, func(bindCtx context.Context, request linkagent.BindingRequest) (string, error) {
			serverURL, _, err := linkagent.ResolveBindingServerURL("", request.ServerURL)
			if err != nil {
				return "", err
			}
			config.ServerURL = serverURL
			identity, err := linkagent.EnrollAgent(bindCtx, serverURL, request.EnrollmentToken, linkagent.EnrollmentMetadata{
				Hostname: config.Hostname, OSFamily: config.OSFamily,
				OSVersion: config.OSVersion, AgentVersion: config.AgentVersion,
				Capabilities: config.Capabilities,
			}, nil)
			if err != nil {
				return "", err
			}
			defer linkagent.ClearIdentity(identity)
			if err := linkagent.SaveAgentIdentity(identity, serverURL); err != nil {
				return "", err
			}
			return identity.Fingerprint, nil
		}, func(err error) {
			log.Printf("local enrollment rejected: %v", err)
		}); err != nil {
			return err
		}
		enrolledIdentity, storedURL, loadErr := linkagent.LoadAgentIdentity()
		if enrolledIdentity != nil {
			linkagent.ClearIdentity(enrolledIdentity)
		}
		config.ServerURL, err = storedURL, loadErr
		if err != nil {
			return errors.New("link agent: enrolled identity could not be reloaded from native keyring")
		}
		if err := linkagent.ValidateAgentWSMetadata(config); err != nil {
			return err
		}
	default:
		return err
	}

	broker := linkagent.NewSessionWorkerBroker(linkagent.NewNativeSessionWorkerLauncher())
	return linkagent.RunStoredAgent(
		ctx,
		config,
		func() (*linkagent.Identity, error) {
			storedIdentity, storedURL, err := linkagent.LoadAgentIdentity()
			if err != nil {
				return nil, err
			}
			if storedURL != config.ServerURL {
				linkagent.ClearIdentity(storedIdentity)
				return nil, errors.New("link agent: pinned server URL changed while running")
			}
			return storedIdentity, nil
		},
		nil,
		broker.Handler,
		func(err error) { log.Printf("WSS connection: %v", err) },
	)
}

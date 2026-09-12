import 'package:flutter/widgets.dart';
import 'package:provider/provider.dart';
import '../services/auth_state.dart';

class AppStrings {
  final String languageCode;
  AppStrings(this.languageCode);

  bool get isRu => languageCode.startsWith('ru');

  static AppStrings of(BuildContext context, {bool listen = true}) {
    final auth = Provider.of<AuthState>(context, listen: listen);
    return AppStrings(auth.localeCode);
  }

  // --- Common ---
  String get cancel => isRu ? 'Отмена' : 'Cancel';
  String get close => isRu ? 'Закрыть' : 'Close';
  String get ok => isRu ? 'ОК' : 'OK';
  String get save => isRu ? 'Сохранить' : 'Save';
  String get delete => isRu ? 'Удалить' : 'Delete';
  String get error => isRu ? 'Ошибка' : 'Error';
  String get success => isRu ? 'Успешно' : 'Success';
  String get loading => isRu ? 'Загрузка...' : 'Loading...';
  String get retry => isRu ? 'Повторить' : 'Retry';
  String get refresh => isRu ? 'Обновить' : 'Refresh';
  String get open => isRu ? 'Открыть' : 'Open';
  String get yes => isRu ? 'Да' : 'Yes';
  String get no => isRu ? 'Нет' : 'No';
  String get enabled => isRu ? 'Включено' : 'Enabled';
  String get disabled => isRu ? 'Выключено' : 'Disabled';
  String get active => isRu ? 'Активен' : 'Active';
  String get role => isRu ? 'Роль' : 'Role';
  String get server => isRu ? 'Сервер' : 'Server';

  // --- Connect Screen ---
  String get connectTitle => 'Ligament 2FA';
  String get connectSubtitle => isRu ? 'Корпоративный аутентификатор доступа' : 'Enterprise Access Authenticator';
  String get serverUrlLabel => isRu ? 'Адрес сервера Ligament' : 'Ligament Server URL';
  String get serverUrlGpoTooltip => isRu ? 'Адрес задан групповой политикой Windows (GPO)' : 'URL enforced by Group Policy (GPO)';
  String get serverUrlGpoLocked => isRu ? '🔒 Настройка заблокирована системным администратором (GPO)' : '🔒 Setting locked by system administrator (GPO)';
  String get errEnterValidHttps => isRu ? 'Введите корректный HTTPS адрес сервера' : 'Please enter a valid HTTPS server URL';
  String get errInvalidServerUrl => isRu ? 'Некорректный адрес сервера' : 'Invalid server URL';
  String get errInsecureHttp => isRu
      ? 'Небезопасное соединение: пароль и токены будут передаваться открытым текстом. Укажите HTTPS-адрес сервера (http:// разрешен только для localhost / 127.*)'
      : 'Insecure connection: password and tokens will be transmitted in plaintext. Please specify an HTTPS server URL (http:// is only allowed for localhost / 127.*)';
  String get errSchemeHttps => isRu
      ? 'Адрес сервера должен начинаться с https:// (http:// — только localhost для отладки)'
      : 'Server URL must start with https:// (http:// is only for localhost debugging)';
  String get errFailedToConnect => isRu ? 'Не удалось подключиться к серверу' : 'Failed to connect to server';
  String get connectBtn => isRu ? 'Подключиться' : 'Connect';
  String get connectButton => connectBtn;

  // --- Login Screen ---
  String get loginWorkstationAuth => isRu ? 'Авторизация рабочего места сотрудника' : 'Workstation Employee Authorization';
  String get authWorkstation => loginWorkstationAuth;
  String get usernameLabel => isRu ? 'Корпоративный логин' : 'Corporate Username';
  String get corporateLogin => usernameLabel;
  String get passwordLabel => isRu ? 'Пароль учетной записи' : 'Account Password';
  String get password => passwordLabel;
  String get codeLabel => isRu ? 'Код подтверждения (TOTP / SMS / TG)' : 'Verification Code (TOTP / SMS / TG)';
  String get codeFieldLabel => isRu ? 'Код подтверждения' : 'Verification Code';
  String get errFillCredentials => isRu ? 'Заполните логин и пароль' : 'Please enter username and password';
  String get errFillUsernamePassword => errFillCredentials;
  String get errEnterCode => isRu ? 'Введите код подтверждения' : 'Please enter verification code';
  String get errEnterVerificationCode => errEnterCode;
  String get errSecondFactorRequired => isRu ? 'Требуется подтверждение вторым фактором' : 'Second factor confirmation required';
  String get secondFactorPrompt => isRu ? 'Введите одноразовый код второго фактора (TOTP/SMS/TG)' : 'Enter one-time two-factor authentication code (TOTP/SMS/TG)';
  String get errBadCode => isRu ? 'Неверный код подтверждения (TOTP / Telegram / SMS)' : 'Invalid verification code (TOTP / Telegram / SMS)';
  String get errInvalidVerificationCode => errBadCode;
  String get errInvalidCredentials => isRu ? 'Неверное имя пользователя или пароль' : 'Invalid username or password';
  String get errCodeExpired => isRu ? 'Неверный код подтверждения или срок действия истёк' : 'Invalid verification code or code expired';
  String get errBadCodeOrExpired => errCodeExpired;
  String get errUserDisabled => isRu ? 'Учетная запись отключена администратором' : 'User account is disabled by administrator';
  String get errAccountLocked => isRu ? 'Учетная запись временно заблокирована из-за частых неудачных попыток' : 'Account is temporarily locked due to too many failed attempts';
  String get errRateLimited => isRu ? 'Слишком много попыток входа. Пожалуйста, подождите.' : 'Too many login attempts. Please wait.';
  String get errBadJson => isRu ? 'Некорректный запрос к серверу' : 'Invalid request to server';
  String get loginBtn => isRu ? 'Войти в аккаунт' : 'Log In';
  String get btnLogin => loginBtn;
  String get btnConfirmAndLogin => isRu ? 'Подтвердить и войти' : 'Verify & Log In';
  String get btnChangeUser => isRu ? 'Сменить' : 'Change';
  String get btnBackToPassword => isRu ? '← Вернуться к вводу пароля' : '← Back to password';
  String get changeServer => isRu ? 'Сменить сервер' : 'Change Server';
  String get loginErrorPrefix => isRu ? 'Ошибка входа' : 'Login error';

  // --- Home Screen ---
  String get navHome => isRu ? 'Главная' : 'Home';
  String get navApps => isRu ? 'Приложения' : 'Apps';
  String get navHistory => isRu ? 'Журнал' : 'Log';
  String get navSettings => isRu ? 'Настройки' : 'Settings';
  String get statusOnline => isRu ? 'В сети' : 'Online';
  String get statusOffline => isRu ? 'Офлайн' : 'Offline';
  String get statusProtected => isRu ? 'Защищен' : 'Protected';
  String get statusWarning => isRu ? 'Внимание' : 'Warning';
  String get connectionActive => isRu ? 'Подключение активно' : 'Connection active';
  String get connectionReconnecting => isRu ? 'Офлайн / Переподключение...' : 'Offline / Reconnecting...';
  String get deviceProtected => isRu ? 'Устройство защищено' : 'Device protected';
  String get deviceNonCompliant => isRu ? 'Нарушение корпоративных политик' : 'Corporate policy violation';
  String get sosTitle => isRu ? 'Экстренная помощь (SOS)' : 'Emergency Support (SOS)';
  String get sosDesc => isRu ? 'Запросить удаленное подключение инженера техподдержки к вашему ПК' : 'Request remote assistance engineer connection to your PC';
  String get sosRequestBtn => isRu ? 'Запросить помощь' : 'Request Assistance';
  String get sosRequested => isRu ? 'Заявка отправлена' : 'Request Submitted';
  String get sosWaitingOperator => isRu ? 'Ожидание подключения инженера техподдержки...' : 'Waiting for support engineer to connect...';
  String get sosCancelRequest => isRu ? 'Отозвать заявку' : 'Cancel Request';
  String get sosSessionActive => isRu ? 'Сеанс помощи активен' : 'Support Session Active';
  String sosConnectedWith(String name) => isRu ? 'Инженер $name подключен к вашему экрану' : 'Engineer $name is connected to your screen';
  String get sosEndSession => isRu ? 'Завершить сеанс' : 'End Session';
  String get sosQueueTitle => isRu ? 'Очередь заявок SOS' : 'SOS Request Queue';
  String get sosQueueEmpty => isRu ? 'Нет активных заявок в очереди' : 'No active requests in queue';
  String get sosConnectBtn => isRu ? 'Подключиться' : 'Connect';
  String get sosChatBtn => isRu ? 'Чат' : 'Chat';
  String get sosEnterCodeBtn => isRu ? 'Ввести код' : 'Enter Code';
  String get activeChallengesTitle => isRu ? 'Запросы подтверждения' : 'Authorization Requests';
  String get noActiveChallenges => isRu ? 'Нет ожидающих запросов' : 'No pending requests';
  String get openFolder => isRu ? 'Открыть папку' : 'Open Folder';
  String get downloadedFiles => isRu ? 'Полученные файлы' : 'Received Files';
  String get errConnection => isRu ? 'Ошибка подключения' : 'Connection error';

  // --- Approval Modal (2FA Push) ---
  String get approvalTitle => isRu ? 'Подтверждение входа' : 'Login Approval';
  String get loginRequestTitle => isRu ? 'Запрос на вход' : 'Login Request';
  String get approvalSub => isRu ? 'Запрос двухфакторной аутентификации' : 'Two-Factor Authentication Request';
  String get serviceLabel => isRu ? 'Куда (сервис):' : 'Service:';
  String get userLabel => isRu ? 'Пользователь:' : 'User:';
  String get ipLabel => isRu ? 'IP клиента:' : 'Client IP:';
  String get serverIpLabel => isRu ? 'Сервер (IP):' : 'Server (IP):';
  String get serverNameLabel => isRu ? 'Имя сервера:' : 'Server Name:';
  String get locationLabel => isRu ? 'Локация:' : 'Location:';
  String get timeLabel => isRu ? 'Время:' : 'Time:';
  String get deviceLabel => isRu ? 'Устройство:' : 'Device:';
  String get employee => isRu ? 'Сотрудник' : 'Employee';
  String get serviceCorpAccess => isRu ? 'Корпоративный доступ' : 'Corporate Access';
  String get numberMatchHeader => isRu ? 'Защита от случайных нажатий (Number Match):' : 'Number Match Verification:';
  String get numberMatchSub => isRu ? 'Выберите число, отображаемое на экране компьютера:' : 'Select the number displayed on your computer screen:';
  String get errSelectMatch => isRu ? 'Выберите верный номер, показанный на экране входа' : 'Select the matching number shown on the login screen';
  String get errWrongMatch => isRu ? 'Выбрано неверное число подтверждения' : 'Incorrect confirmation number selected';
  String get errNonCompliant => isRu
      ? 'Вход заблокирован: устройство не соответствует требованиям безопасности (отключен BitLocker или обнаружен root)'
      : 'Login blocked: device does not comply with security requirements (BitLocker disabled or root detected)';
  String get errExpired => isRu ? 'Время действия запроса истекло' : 'Request has expired';
  String get errWinHello => isRu ? 'Подтверждение Windows Hello отклонено' : 'Windows Hello confirmation rejected';
  String get approveBtn => isRu ? 'Принять' : 'Approve';
  String get denyBtn => isRu ? 'Отклонить' : 'Deny';
  String get secondsRemaining => isRu ? 'сек' : 's';
  String get secondsShort => isRu ? 'с' : 's';
  String get privateIpBadge => isRu ? '(внутренний IP)' : '(private IP)';
  String get workstation => isRu ? 'Рабочая станция' : 'Workstation';
  String get androidDevice => isRu ? 'Android Устройство' : 'Android Device';
  String get iosDevice => isRu ? 'iOS Устройство' : 'iOS Device';

  // --- Apps Screen ---
  String get appsTitle => isRu ? 'Корпоративные приложения (SSO)' : 'Enterprise Applications (SSO)';
  String get appsRefresh => isRu ? 'Обновить каталог' : 'Refresh Catalog';
  String get appsEmptyTitle => isRu ? 'Доступных SSO приложений нет' : 'No SSO apps available';
  String get appsEmptySub => isRu ? 'Администратор еще не назначил права доступа к сервисам' : 'Administrator has not granted access to any services yet';
  String get appsCantOpen => isRu ? 'Не удалось открыть ссылку' : 'Could not open link';

  // --- History Screen ---
  String get historyTitle => isRu ? 'Журнал безопасности' : 'Security Log';
  String get notYouTitle => isRu ? 'Это были не вы?' : 'Wasn\'t you?';
  String get notYouSub => isRu
      ? 'Если вы заметили подозрительную активность входа, немедленно выйдите из приложения. Все активные сессии на данном устройстве будут заблокированы.'
      : 'If you notice suspicious login activity, log out immediately. All active sessions on this device will be revoked.';
  String get emergencyExit => isRu ? 'Экстренный выход' : 'Emergency Logout';
  String get statusSuccess => isRu ? 'Успешно' : 'Success';
  String get statusFailed => isRu ? 'Ошибка' : 'Failed';
  String get detailsTitle => isRu ? 'Детали события' : 'Event Details';
  String get colStatus => isRu ? 'Статус:' : 'Status:';
  String get colService => isRu ? 'Куда (сервис):' : 'Service:';
  String get colClientIp => isRu ? 'IP клиента:' : 'Client IP:';
  String get colServerIp => isRu ? 'IP сервера:' : 'Server IP:';
  String get colLocation => isRu ? 'Местоположение:' : 'Location:';
  String get colDevice => isRu ? 'Устройство:' : 'Device:';
  String get colBrowser => isRu ? 'Браузер / ОС:' : 'Browser / OS:';
  String get colMethod => isRu ? 'Метод:' : 'Method:';
  String get colTime => isRu ? 'Время события:' : 'Event Time:';
  String get historyEmpty => isRu ? 'История событий пуста' : 'Event history is empty';

  // --- Support Dialog (SOS Request) ---
  String get supportReqTitle => isRu ? 'Экстренная помощь (SOS)' : 'Emergency Support (SOS)';
  String get supportReqSubtitle => isRu ? 'Удаленный доступ к вашему рабочему месту' : 'Remote access to your workstation';
  String get selectDept => isRu ? 'Выберите службу поддержки:' : 'Select Support Department:';
  String get problemSummaryLabel => isRu ? 'Кратко опишите проблему:*' : 'Brief problem description:*';
  String get problemSummaryHint1C => isRu ? 'Например: Зависает проведение документа в 1С:Бухгалтерия...' : 'E.g.: Document posting hangs in 1C:Accounting...';
  String get problemSummaryHintIt => isRu ? 'Например: Не открывается сетевая папка, ошибка сетевого принтера...' : 'E.g.: Network folder won\'t open, network printer error...';
  String get problemSummaryValidation => isRu ? 'Пожалуйста, опишите суть возникшей проблемы' : 'Please describe the problem';
  String get problemSummaryMinLen => isRu ? 'Описание должно быть не менее 5 символов' : 'Description must be at least 5 characters';
  String get remoteAccessMode => isRu ? 'Режим удаленного доступа:' : 'Remote Access Mode:';
  String get modeFullControl => isRu ? '🎮 Полный доступ (управление мышью и клавиатурой)' : '🎮 Full Control (mouse & keyboard control)';
  String get modeViewOnly => isRu ? '👀 Только просмотр экрана (без управления)' : '👀 View Only (screen view only)';
  String get sendRequestBtn => isRu ? 'Отправить SOS запрос' : 'Send SOS Request';
  String requestSentNotice(String cat) => isRu ? 'Запрос передан в службу: $cat. Ожидайте подключения инженера.' : 'Request submitted to: $cat. Please wait for an engineer to connect.';
  String get errSendRequest => isRu ? 'Не удалось отправить запрос' : 'Failed to send request';

  // --- Support Approval Modal (Client side) ---
  String get supportApprovalTitleFull => isRu ? 'Запрос на управление вашим ПК' : 'Request to Control Your PC';
  String get supportApprovalTitleView => isRu ? 'Запрос на просмотр вашего экрана' : 'Request to View Your Screen';
  String get oneCReady => isRu ? 'Консультант 1С готов помочь вам' : '1C Consultant is ready to assist';
  String get itOnDuty => isRu ? 'Дежурный инженер IT на связи' : 'IT Engineer on duty is connected';
  String get defaultEngineer => isRu ? 'Инженер техподдержки' : 'Support Engineer';
  String get oneCSupportBadge => isRu ? '1С-поддержка' : '1C Support';
  String get itSupportBadge => isRu ? 'IT-служба' : 'IT Helpdesk';
  String get problemSummaryPrefix => isRu ? 'Суть проблемы:' : 'Problem summary:';
  String get fullControlDesc => isRu ? 'Полный доступ: управление мышью и клавиатурой' : 'Full access: mouse & keyboard control';
  String get viewOnlyDesc => isRu ? 'Только просмотр экрана (без управления)' : 'View only: no mouse/keyboard control';
  String get numberMatchTitle => isRu ? 'Контрольное число Number Matching' : 'Number Matching Code';
  String get numberMatchVoiceDesc => isRu
      ? 'Специалист поддержки продиктовал вам число по телефону.\nВведите его вручную — выбор «наугад» невозможен.'
      : 'The support specialist gave you a number by phone/voice.\nEnter it manually — guessing is disabled.';
  String get noCodeNotice => isRu
      ? 'Запрос без контрольного числа. Подтверждение невозможно —\nобратитесь в поддержку по официальному каналу.'
      : 'Request without verification number. Approval not possible —\ncontact support via official channels.';
  String get allowAccessBtn => isRu ? 'Разрешить доступ' : 'Allow Access';
  String get errEnterMatch => isRu ? 'Введите контрольное число полностью' : 'Please enter the complete verification code';
  String get errWrongMatchPhone => isRu ? 'Неверное контрольное число. Сверьте число со специалистом' : 'Incorrect verification code. Please check with the specialist';
  String get errApprovalPrefix => isRu ? 'Ошибка подтверждения' : 'Approval error';

  // --- Support Operator Screen ---
  String get operatorTitle => isRu ? 'Управление экраном' : 'Remote Screen Control';
  String get controlEnabled => isRu ? 'Управление активно' : 'Control Enabled';
  String get controlDisabled => isRu ? 'Только просмотр' : 'View Only';
  String get numberMatchPrompt => isRu ? 'Контрольный код Zero-Trust' : 'Zero-Trust Verification Code';
  String get numberMatchOperatorSub => isRu ? 'Сообщите сотруднику код для ввода на его экране:' : 'Provide this code to the employee to enter on their screen:';
  String get waitingUserApproval => isRu ? 'Ожидание подтверждения сотрудником...' : 'Waiting for employee confirmation...';
  String get btnToggleControl => isRu ? 'Управление' : 'Control';
  String get btnBlockInput => isRu ? 'Блок ввода' : 'Block Input';
  String get btnUnblockInput => isRu ? 'Разблок' : 'Unblock';
  String get scaleFit => isRu ? 'Вписать' : 'Fit';
  String get scale1to1 => '1:1';
  String get hotkeys => isRu ? 'Горячие клавиши' : 'Hotkeys';
  String get clipboard => isRu ? 'Буфер' : 'Clipboard';
  String get chat => isRu ? 'Чат' : 'Chat';
  String get files => isRu ? 'Файлы' : 'Files';
  String get clipboardSyncTitle => isRu ? 'Буфер обмена' : 'Clipboard';
  String get sendToClient => isRu ? 'Отправить клиенту' : 'Send to Client';
  String get readFromClient => isRu ? 'Прочитать с клиента' : 'Read from Client';
  String get chatInputPlaceholder => isRu ? 'Введите сообщение...' : 'Type a message...';
  String get send => isRu ? 'Отправить' : 'Send';
  String get fileTransferTitle => isRu ? 'Передача файлов' : 'File Transfer';
  String get dropFilesHere => isRu ? 'Отпустите файлы для передачи' : 'Drop files here to transfer';
  String get endSessionTitle => isRu ? 'Завершить сеанс?' : 'End Session?';
  String get endSessionSub => isRu ? 'Удаленное подключение к ПК пользователя будет немедленно прекращено.' : 'Remote connection to the user PC will be terminated immediately.';
  String get endSession => isRu ? 'Завершить' : 'End Session';
  String get selectFile => isRu ? 'Выбрать на диске' : 'Select File';
  String get receivedFromClipboard => isRu ? 'Получено из буфера:' : 'Received from clipboard:';
  String get initStatus => isRu ? 'Инициализация...' : 'Initializing...';
  String get chatModeStatus => isRu ? 'Режим чата' : 'Chat Mode';
  String waitingUserConsent(String code) => isRu ? 'Ожидание согласия пользователя ($code)...' : 'Waiting for user consent ($code)...';
  String get sessionEndedByServer => isRu ? 'Сеанс завершен сервером' : 'Session ended by server';
  String get connErrorPrefix => isRu ? 'Ошибка соединения:' : 'Connection error:';
  String get requestingScreenAccess => isRu ? 'Запрос доступа к экрану у пользователя...' : 'Requesting screen access from user...';
  String get reqErrorPrefix => isRu ? 'Ошибка запроса:' : 'Request error:';
  String get reqScreenErrorPrefix => isRu ? 'Ошибка запроса экрана:' : 'Screen request error:';
  String get p2pConnected => isRu ? 'Подключено (P2P)' : 'Connected (P2P)';
  String get streamActive => isRu ? 'Трансляция активна' : 'Stream Active';
  String get sessionEndedByUser => isRu ? 'Сеанс поддержки был завершен пользователем' : 'Support session was ended by the user';
  String get defaultEngineerName => isRu ? 'Инженер' : 'Engineer';
  String get defaultClientName => isRu ? 'Клиент' : 'Client';
  String chatWithUser(String name) => isRu ? 'Чат с пользователем • $name' : 'Chat with user • $name';
  String get chatEmptyPrompt => isRu ? 'Сообщений пока нет.\nНапишите пользователю приветствие или инструкцию.' : 'No messages yet.\nWrite a greeting or instruction to the user.';
  String get chatInputHint => isRu ? 'Написать сообщение пользователю...' : 'Type a message to the user...';
  String get textInputTitle => isRu ? 'Ввод текста на ПК клиента' : 'Input Text on Client PC';
  String get textInputPrompt => isRu ? 'Введите текст или команду для отправки на компьютер клиента:' : 'Enter text or command to send to client computer:';
  String get textInputPlaceholder => isRu ? 'Текст, пароль или команда...' : 'Text, password or command...';
  String get quickKeys => isRu ? 'Быстрые клавиши:' : 'Quick keys:';
  String get localClipboardEmpty => isRu ? 'Локальный буфер обмена пуст' : 'Local clipboard is empty';
  String clipboardSentNotice(int len) => isRu ? 'Буфер отправлен на ПК клиента ($len симв.)' : 'Clipboard sent to client PC ($len chars)';
  String get clientClipboardTitle => isRu ? 'Буфер обмена клиента' : 'Client Clipboard';
  String get clipboardEmpty => isRu ? '(Буфер обмена пуст)' : '(Clipboard is empty)';
  String get copiedToLocalClipboard => isRu ? 'Скопировано в ваш локальный буфер' : 'Copied to your local clipboard';
  String get copyToMyself => isRu ? 'Скопировать себе' : 'Copy to Local';
  String get confirmEndSessionTitle => isRu ? 'Завершить сеанс?' : 'End Session?';
  String get confirmEndSessionDesc => isRu ? 'Вы уверены, что хотите завершить сеанс удаленного управления?' : 'Are you sure you want to end this remote control session?';
  String get monitor => isRu ? 'Монитор' : 'Monitor';
  String get refreshScreensTooltip => isRu ? 'Обновить список экранов (Win+P "Расширить" на клиенте)' : 'Refresh display list (Win+P "Extend" on client)';
  String get refreshScreensSent => isRu ? 'Запрос обновления списка экранов отправлен...' : 'Display list refresh request sent...';
  String get zoomFitTooltip => isRu ? 'Масштаб: Вписать' : 'Zoom: Fit';
  String get zoom1to1Tooltip => isRu ? 'Масштаб: 1:1' : 'Zoom: 1:1';
  String get zoomInTooltip => isRu ? 'Приблизить' : 'Zoom In';
  String get zoomOutTooltip => isRu ? 'Отдалить' : 'Zoom Out';
  String get unblockClientInputTooltip => isRu ? 'Разблокировать мышь клиента' : 'Unblock client mouse';
  String get blockClientInputTooltip => isRu ? 'Заблокировать мышь/клавиатуру клиента' : 'Block client mouse/keyboard';
  String get controlEnabledTooltip => isRu ? 'Управление активно (кликните для паузы)' : 'Control active (click to pause)';
  String get controlDisabledTooltip => isRu ? 'Только просмотр (кликните для включения)' : 'View only (click to enable control)';
  String get controlEnabledNotice => isRu ? '🎮 Управление включено' : '🎮 Control enabled';
  String get controlDisabledNotice => isRu ? '👁 Режим только просмотра' : '👁 View only mode';
  String get enterTextTooltip => isRu ? 'Ввести текст/команду на ПК клиента' : 'Enter text/command on client PC';
  String get rightClickModeTooltip => isRu ? 'Режим: Правый клик (ПКМ)' : 'Mode: Right click';
  String get leftClickModeTooltip => isRu ? 'Режим: Левый клик (ЛКМ)' : 'Mode: Left click';
  String get rightClickNotice => isRu ? '🖱 Следующий клик: Правая кнопка (ПКМ)' : '🖱 Next click: Right click';
  String get leftClickNotice => isRu ? '🖱 Режим: Обычный клик (ЛКМ)' : '🖱 Mode: Regular click (Left)';
  String get rightClickModeShort => isRu ? 'Режим: ПКМ' : 'Mode: Right';
  String get leftClickModeShort => isRu ? 'Режим: ЛКМ' : 'Mode: Left';
  String get requestScreen2fa => isRu ? 'Запросить экран (2FA)' : 'Request Screen (2FA)';
  String get numberMatchForClient => isRu ? 'Контрольное число для клиента (2FA):' : 'Verification code for client (2FA):';
  String get numberMatchHintClient => isRu ? 'Пользователь должен выбрать или подтвердить это число на своем экране' : 'User must enter or confirm this code on their screen';
  String get chatModeTitle => isRu ? 'Текстовый чат с пользователем' : 'Text Chat with User';
  String get chatModeDesc => isRu
      ? 'Вы находитесь в режиме прямого чата.\nТрансляция экрана начнется после запроса доступа и 2FA подтверждения.'
      : 'You are in direct chat mode.\nScreen streaming will start after access request and 2FA confirmation.';
  String get requestScreenAccessBtn => isRu ? '🎮 Запросить доступ к экрану (2FA)' : '🎮 Request Screen Access (2FA)';
  String get openChatWindowBtn => isRu ? '💬 Открыть окно чата' : '💬 Open Chat Window';
  String get scrollUp => isRu ? 'Скролл ▲' : 'Scroll ▲';
  String get scrollDown => isRu ? 'Скролл ▼' : 'Scroll ▼';
  String get enterTextBtn => isRu ? 'Ввод текста' : 'Enter Text';
  String get sendLocalBuffer => isRu ? '⬆ Отправить мой буфер клиенту' : '⬆ Send my clipboard to client';
  String get readRemoteBuffer => isRu ? '⬇ Прочитать буфер с ПК клиента' : '⬇ Read clipboard from client PC';
  String get backTooltip => isRu ? 'Назад' : 'Back';
  String get hotkeysTooltip => isRu ? 'Горячие клавиши' : 'Hotkeys';
  String get clipboardTooltip => isRu ? 'Буфер обмена' : 'Clipboard';
  String get chatWithUserTooltip => isRu ? 'Чат с пользователем' : 'Chat with user';
  String get hotkeyWin => isRu ? '⊞ Пуск (Win)' : '⊞ Start (Win)';
  String get hotkeyWinR => isRu ? '⊞ Win + R (Выполнить)' : '⊞ Win + R (Run)';
  String get hotkeyWinE => isRu ? '⊞ Win + E (Проводник)' : '⊞ Win + E (Explorer)';
  String get hotkeyWinX => isRu ? '⊞ Win + X (Админ-меню)' : '⊞ Win + X (Admin Menu)';
  String get hotkeyWinD => isRu ? '⊞ Win + D (Рабочий стол)' : '⊞ Win + D (Desktop)';
  String get hotkeyWinL => isRu ? '⊞ Win + L (Блокировка)' : '⊞ Win + L (Lock)';
  String get hotkeyTaskMgr => isRu ? '⚡ Диспетчер задач' : '⚡ Task Manager';
  String get clientFallback => isRu ? 'Клиент' : 'Client';
  String get gbUnit => isRu ? 'ГБ' : 'GB';
  String get chatTitle => isRu ? 'Чат' : 'Chat';

  // --- Settings Screen ---
  String get settingsTitle => isRu ? 'Безопасность и профиль' : 'Security & Profile';
  String get userFallback => isRu ? 'Пользователь' : 'User';
  String userRole(String r) => isRu ? 'Роль: $r' : 'Role: $r';
  String serverUrl(String u) => isRu ? 'Сервер: $u' : 'Server: $u';
  String get languageSection => isRu ? 'Язык интерфейса' : 'Interface Language';
  String get languageRussian => isRu ? 'Русский' : 'Russian';
  String get languageEnglish => 'English';
  String get gpoMac => isRu ? 'Политики безопасности macOS (MDM)' : 'macOS Security Policies (MDM)';
  String get gpoWin => isRu ? 'Групповые политики Windows (GPO)' : 'Windows Group Policy (GPO)';
  String get gpoCorp => isRu ? 'Корпоративные политики безопасности' : 'Corporate Security Policies';
  String get centralManagement => isRu ? 'Централизованное управление' : 'Centralized Management';
  String get activeMdm => isRu ? 'Активно (MDM Profile)' : 'Active (MDM Profile)';
  String get activeGpo => isRu ? 'Активно (ADMX/GPO)' : 'Active (ADMX/GPO)';
  String get notAssigned => isRu ? 'Не назначено' : 'Not assigned';
  String get reqTouchId => isRu ? 'Требование Touch ID / пароля' : 'Require Touch ID / Password';
  String get reqWinHello => isRu ? 'Требование Windows Hello' : 'Require Windows Hello';
  String get reqFileVault => isRu ? 'Требование шифрования FileVault' : 'Require FileVault Encryption';
  String get reqBitLocker => isRu ? 'Требование BitLocker' : 'Require BitLocker';
  String get appExit => isRu ? 'Выход из приложения' : 'App Exit';
  String get allowed => isRu ? 'Разрешен' : 'Allowed';
  String get blockedByPolicy => isRu ? 'Запрещен политикой безопасности' : 'Blocked by security policy';
  String get securityTelemetry => isRu ? 'Телеметрия безопасности' : 'Security Telemetry';
  String get complianceStatus => isRu ? 'Статус соответствия' : 'Compliance Status';
  String get compliant => isRu ? 'Соответствует корпоративным политикам' : 'Compliant with corporate policies';
  String get nonCompliant => isRu ? 'Нарушение комплаенса' : 'Compliance violation';
  String get fileVaultEnc => isRu ? 'Шифрование FileVault' : 'FileVault Encryption';
  String get fileVaultOn => isRu ? 'Защищен (FileVault On)' : 'Protected (FileVault On)';
  String get gatekeeper => isRu ? 'Защита Gatekeeper' : 'Gatekeeper Protection';
  String get macosFirewall => isRu ? 'Сетевой экран macOS' : 'macOS Firewall';
  String get touchId => isRu ? 'Биометрия Touch ID' : 'Touch ID Biometrics';
  String get touchIdAvailable => isRu ? 'Настроен и доступен' : 'Configured and available';
  String get touchIdNotConfigured => isRu ? 'Не настроен' : 'Not configured';
  String get bitLockerEnc => isRu ? 'Шифрование BitLocker' : 'BitLocker Encryption';
  String get bitLockerProtected => isRu ? 'Защищен (100%)' : 'Protected (100%)';
  String get defender => isRu ? 'Антивирус Windows Defender' : 'Windows Defender Antivirus';
  String get winFirewall => isRu ? 'Брандмауэр Windows' : 'Windows Firewall';
  String get linuxFirewall => isRu ? 'Брандмауэр Linux' : 'Linux Firewall';
  String get rootJailbreak => 'Root / Jailbreak';
  String get rootDetected => isRu ? 'ОБНАРУЖЕН!' : 'DETECTED!';
  String get rootClean => isRu ? 'Целостность чиста' : 'Integrity Clean';
  String get storageDisk => isRu ? 'Накопитель (Диск)' : 'Storage (Disk)';
  String get cpuLoad => isRu ? 'Загрузка процессора (CPU)' : 'CPU Usage';
  String get logoutAccount => isRu ? 'Выйти из учетной записи' : 'Log Out of Account';
  String get logoutBlocked => isRu ? 'Выход заблокирован системным администратором' : 'Logout blocked by system administrator';
  String platformCorporate(String p) => isRu ? 'Платформа: $p • Корпоративная защита' : 'Platform: $p • Enterprise Protection';

  // --- Tray ---
  String get trayOpen => isRu ? 'Открыть Ligament 2FA' : 'Open Ligament 2FA';
  String get trayExit => isRu ? 'Выход' : 'Exit';
}

extension BuildContextI18n on BuildContext {
  AppStrings get strings => AppStrings.of(this);
  AppStrings get stringsRead => AppStrings.of(this, listen: false);
}

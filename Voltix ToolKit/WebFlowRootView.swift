import AdjustSdk
import AdSupport
import AppTrackingTransparency
import SwiftUI
import UIKit
@preconcurrency import WebKit

private enum WebBootstrapPhase: Equatable {
    case loading
    case native
    case web(String)
}

private extension Notification.Name {
    static let webFlowShouldShowFallback = Notification.Name("webFlowShouldShowFallback")
    static let debugLogsRequested = Notification.Name("debugLogsRequested")
}

private enum WebFlowFallback {
    static let reasonKey = "reason"
}

final class DebugLogStore: ObservableObject {
    static let shared = DebugLogStore()

    @Published private(set) var lines: [String] = []

    private let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    func append(_ message: String) {
        DispatchQueue.main.async {
            let timestamp = self.formatter.string(from: Date())
            self.lines.append("[\(timestamp)] \(message)")
            if self.lines.count > 500 {
                self.lines.removeFirst(self.lines.count - 500)
            }
        }
    }

    func clear() {
        DispatchQueue.main.async {
            self.lines.removeAll()
        }
    }

    var text: String {
        lines.joined(separator: "\n")
    }
}

private final class WebBootstrapViewModel: ObservableObject {
    @Published var phase: WebBootstrapPhase = .loading

    private let generatedClientUUIDKey = "generatedClientUUID"
    private let bootstrapEndpoint = "https://voltixtoolkit.cyou/app.php"
    private let userAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_3 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"
    private let referrer = "utm_source=appstore&utm_medium=organic"

    private var isBootstrapping = false
    private var hasCreatedSessionThisLaunch = false
    private var lastHandledPushIDThisLaunch: String = ""

    @MainActor
    func start() {
        let pendingPushID = (UserDefaults.standard.string(forKey: "lastPushId") ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if hasCreatedSessionThisLaunch, pendingPushID.isEmpty {
            print("WEB FLOW skip start: session already created in this launch")
            return
        }
        guard !isBootstrapping else { return }
        isBootstrapping = true

        Task {
            await bootstrap(trigger: "start")
            await MainActor.run { self.isBootstrapping = false }
        }
    }

    @MainActor
    func handlePushOrTokenUpdate(trigger: String) {
        let pendingPushID = (UserDefaults.standard.string(forKey: "lastPushId") ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if trigger == "tokenReceived", hasCreatedSessionThisLaunch {
            return
        }
        if trigger == "pushClicked", hasCreatedSessionThisLaunch, pendingPushID.isEmpty {
            print("WEB FLOW skip pushClicked: session already created and push_id is empty")
            return
        }
        if trigger == "pushClicked",
           !pendingPushID.isEmpty,
           pendingPushID == lastHandledPushIDThisLaunch {
            print("WEB FLOW skip pushClicked: duplicate push_id=\(pendingPushID)")
            return
        }
        guard !isBootstrapping else { return }
        isBootstrapping = true

        Task {
            await bootstrap(trigger: trigger)
            await MainActor.run { self.isBootstrapping = false }
        }
    }

    @MainActor
    func handleWebFlowFailure(reason: String) {
        if shouldClearTaskLinkOnFallback(reason: reason) {
            UserDefaults.standard.removeObject(forKey: "taskLink")
        }
        phase = .native
    }

    private func bootstrap(trigger: String) async {
        DebugLogStore.shared.append("Bootstrap start trigger=\(trigger)")
        await requestPushPermissionAndRegister()
        try? await Task.sleep(nanoseconds: 500_000_000)
        await requestATTAndStoreIDFA()
        await waitForFCMToken(upToSeconds: 5)
        print("WEB FLOW bootstrap trigger=\(trigger)")
        DebugLogStore.shared.append("Bootstrap after tokens trigger=\(trigger)")

        let cachedTaskLink = normalizeURLString(UserDefaults.standard.string(forKey: "taskLink"))
        if let cachedTaskLink {
            DebugLogStore.shared.append("Cached taskLink exists: \(cachedTaskLink)")
        }

        if normalizeURLString(UserDefaults.standard.string(forKey: "controlsLink")) == nil {
            DebugLogStore.shared.append("controlsLink missing, fetching service-link")
            await configureControlsLink()
        }

        guard let controlsLinkString = normalizeURLString(UserDefaults.standard.string(forKey: "controlsLink")) else {
            DebugLogStore.shared.append("controlsLink missing after fetch, fallback")
            await showCachedTaskLinkOrNative(cachedTaskLink, trigger: trigger)
            return
        }
        DebugLogStore.shared.append("controlsLink=\(controlsLinkString)")

        let fcmToken = UserDefaults.standard.string(forKey: "fcmToken") ?? "null"
        print("WEB FLOW bootstrap fcmToken trigger=\(trigger) value=\(fcmToken)")
        DebugLogStore.shared.append("FCM token=\(fcmToken)")

        let storedClientID = (UserDefaults.standard.string(forKey: "client_id") ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let pushID = UserDefaults.standard.string(forKey: "lastPushId") ?? ""
        let adjustID = await Adjust.adid() ?? ""
        let idfa = UserDefaults.standard.string(forKey: "idfa") ?? ""
        let deviceModel = await MainActor.run { UIDevice.current.model }
        DebugLogStore.shared.append("IDs client_id=\(storedClientID) push_id=\(pushID) adjust_id=\(adjustID) idfa=\(idfa) device=\(deviceModel)")

        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "firebase_push_token", value: fcmToken),
            URLQueryItem(name: "adjust_id", value: adjustID),
            URLQueryItem(name: "idfa", value: idfa),
            URLQueryItem(name: "device_model", value: deviceModel)
        ]
        if isValidUUID(storedClientID) {
            queryItems.append(URLQueryItem(name: "client_id", value: storedClientID))
        }
        if !pushID.isEmpty {
            queryItems.append(URLQueryItem(name: "push_id", value: pushID))
        }

        var components = URLComponents(string: controlsLinkString)
        components?.queryItems = queryItems

        guard let controlsURL = components?.url else {
            DebugLogStore.shared.append("Failed to build controls URL from \(controlsLinkString)")
            await showCachedTaskLinkOrNative(cachedTaskLink, trigger: trigger)
            return
        }

        var request = URLRequest(url: controlsURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let adjustAttribution = await waitForAdjustAttribution(upToSeconds: 13)
        let requestBody: [String: Any] = [
            "adjust": adjustAttribution,
            "referrer": referrer
        ]
        DebugLogStore.shared.append("POST url=\(controlsURL.absoluteString)")
        DebugLogStore.shared.append("POST body=\(jsonString(from: requestBody))")
        request.httpBody = (try? JSONSerialization.data(withJSONObject: requestBody, options: [])) ?? Data("{}".utf8)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let httpResponse = response as? HTTPURLResponse, !(200...299).contains(httpResponse.statusCode) {
                print("WEB FLOW bootstrap bad status=\(httpResponse.statusCode)")
                DebugLogStore.shared.append("POST response bad status=\(httpResponse.statusCode) body=\(String(data: data, encoding: .utf8) ?? "")")
                await showCachedTaskLinkOrNative(cachedTaskLink, trigger: trigger)
                return
            }
            if let httpResponse = response as? HTTPURLResponse {
                DebugLogStore.shared.append("POST response status=\(httpResponse.statusCode) body=\(String(data: data, encoding: .utf8) ?? "")")
            }
            let decoded = try JSONDecoder().decode(WebFlowResponse.self, from: data)
            UserDefaults.standard.set(decoded.clientID, forKey: "client_id")
            DebugLogStore.shared.append("Decoded response client_id=\(decoded.clientID) response=\(decoded.response ?? "nil")")

            if let taskLink = normalizeURLString(decoded.response) {
                UserDefaults.standard.set(taskLink, forKey: "taskLink")
                DebugLogStore.shared.append("Opening taskLink=\(taskLink)")
                if !pushID.isEmpty {
                    await MainActor.run { self.lastHandledPushIDThisLaunch = pushID }
                }
                if !pushID.isEmpty {
                    UserDefaults.standard.removeObject(forKey: "lastPushId")
                }
                await MainActor.run { self.hasCreatedSessionThisLaunch = true }
                await MainActor.run { self.phase = .web(taskLink) }
            } else {
                DebugLogStore.shared.append("Decoded response has no valid taskLink, fallback native")
                await MainActor.run { self.phase = .native }
            }
        } catch {
            print("WEB FLOW bootstrap error=\(error.localizedDescription)")
            DebugLogStore.shared.append("POST error=\(error.localizedDescription)")
            await showCachedTaskLinkOrNative(cachedTaskLink, trigger: trigger)
        }
    }

    @MainActor
    private func showCachedTaskLinkOrNative(_ cachedTaskLink: String?, trigger: String) {
        if trigger == "start", let cachedTaskLink {
            phase = .web(cachedTaskLink)
        } else {
            phase = .native
        }
    }

    @MainActor
    private func requestPushPermissionAndRegister() async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()

        if settings.authorizationStatus == .notDetermined {
            do {
                let granted = try await center.requestAuthorization(options: [.alert, .badge, .sound])
                DebugLogStore.shared.append("Push permission requested granted=\(granted)")
            } catch {
                DebugLogStore.shared.append("Push permission error=\(error.localizedDescription)")
            }
        }

        UIApplication.shared.registerForRemoteNotifications()
        DebugLogStore.shared.append("Registered for remote notifications")
    }

    private func waitForFCMToken(upToSeconds seconds: Int) async {
        for _ in 0..<(seconds * 4) {
            let token = (UserDefaults.standard.string(forKey: "fcmToken") ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !token.isEmpty, token != "null" {
                DebugLogStore.shared.append("FCM token ready after wait: \(token)")
                return
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        DebugLogStore.shared.append("FCM token wait timed out")
    }

    @MainActor
    private func requestATTAndStoreIDFA() async {
        guard #available(iOS 14.5, *) else {
            let idfa = ASIdentifierManager.shared().advertisingIdentifier.uuidString
            UserDefaults.standard.set(idfa, forKey: "idfa")
            DebugLogStore.shared.append("ATT unavailable, IDFA=\(idfa)")
            return
        }

        let currentStatus = ATTrackingManager.trackingAuthorizationStatus
        if currentStatus != .notDetermined {
            let idfa = currentStatus == .authorized
                ? ASIdentifierManager.shared().advertisingIdentifier.uuidString
                : ""
            UserDefaults.standard.set(idfa, forKey: "idfa")
            DebugLogStore.shared.append("ATT already decided status=\(currentStatus.rawValue) IDFA=\(idfa)")
            return
        }

        for _ in 0..<10 where UIApplication.shared.applicationState != .active {
            try? await Task.sleep(nanoseconds: 300_000_000)
        }

        guard UIApplication.shared.applicationState == .active else {
            DebugLogStore.shared.append("ATT request skipped: app is not active")
            return
        }

        let status = await Adjust.requestAppTrackingAuthorization()
        let idfa = status == 3
            ? ASIdentifierManager.shared().advertisingIdentifier.uuidString
            : ""
        UserDefaults.standard.set(idfa, forKey: "idfa")
        DebugLogStore.shared.append("ATT requested via Adjust status=\(status) IDFA=\(idfa)")
    }

    private func waitForAdjustAttribution(upToSeconds seconds: Int) async -> [String: Any] {
        DebugLogStore.shared.append("Waiting Adjust attribution from storage timeout=\(seconds)s")
        let deadline = Date().addingTimeInterval(TimeInterval(seconds))
        repeat {
            if let jsonDictionary = storedAdjustAttributionDictionary() {
                let normalizedAttribution = normalizedAdjustAttribution(from: jsonDictionary)
                DebugLogStore.shared.append("Stored Adjust attribution=\(jsonString(from: normalizedAttribution))")
                return normalizedAttribution
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
        } while Date() < deadline

        DebugLogStore.shared.append("No Adjust attribution in storage, sending empty adjust")
        return [:]
    }

    private func storedAdjustAttributionDictionary() -> [String: Any]? {
        guard let jsonString = UserDefaults.standard.string(forKey: "lastAdjustAttribution"),
              let jsonData = jsonString.data(using: .utf8),
              !jsonData.isEmpty,
              let jsonDictionary = try? JSONSerialization.jsonObject(with: jsonData, options: []) as? [String: Any] else {
            return nil
        }

        return jsonDictionary
    }

    private func normalizedAdjustAttribution(from jsonDictionary: [String: Any]) -> [String: Any] {
        let jsonString: String
        if let data = try? JSONSerialization.data(withJSONObject: jsonDictionary, options: []),
           let encoded = String(data: data, encoding: .utf8) {
            jsonString = encoded
        } else {
            jsonString = UserDefaults.standard.string(forKey: "lastAdjustAttribution") ?? ""
        }

        return [
            "trackerToken": jsonDictionary["trackerToken"] as? String ?? "",
            "trackerName": jsonDictionary["trackerName"] as? String ?? "",
            "network": jsonDictionary["network"] as? String ?? "",
            "campaign": jsonDictionary["campaign"] as? String ?? "",
            "adgroup": jsonDictionary["adgroup"] as? String ?? "",
            "creative": jsonDictionary["creative"] as? String ?? "",
            "clickLabel": jsonDictionary["clickLabel"] as? String ?? "",
            "costType": jsonDictionary["costType"] as? String ?? "",
            "costAmount": jsonDictionary["costAmount"] as? Double ?? 0,
            "costCurrency": jsonDictionary["costCurrency"] as? String ?? "",
            "jsonResponse": jsonString
        ]
    }

    private func configureControlsLink() async {
        var userID = normalizedNonLegacyClientUUID(UserDefaults.standard.string(forKey: "userId")) ?? ""
        if userID.isEmpty {
            userID = normalizedNonLegacyClientUUID(UserDefaults.standard.string(forKey: "workingClientUUID")) ?? generatedClientUUID()
            if userID.isEmpty {
                userID = UUID().uuidString
            }
            UserDefaults.standard.set(userID, forKey: "userId")
        }

        guard let serviceLink = await fetchServiceLink() else {
            return
        }

        if let normalized = normalizeURLString(serviceLink) {
            UserDefaults.standard.set(normalized, forKey: "controlsLink")
        }
    }

    private func fetchServiceLink() async -> String? {
        guard let url = URL(string: "\(bootstrapEndpoint)?action=check_info") else {
            return nil
        }

        let clientUUID = normalizedNonLegacyClientUUID(UserDefaults.standard.string(forKey: "userId")) ?? "1"
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(clientUUID, forHTTPHeaderField: "client-uuid")
        DebugLogStore.shared.append("service-link request url=\(url.absoluteString) client-uuid=\(clientUUID)")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else { return nil }
            DebugLogStore.shared.append("service-link response status=\(httpResponse.statusCode) headers=\(httpResponse.allHeaderFields) body=\(String(data: data, encoding: .utf8) ?? "")")
            if let serviceLink = extractServiceLink(from: httpResponse, bodyData: data) {
                rememberWorkingClientUUID(clientUUID)
                DebugLogStore.shared.append("service-link extracted=\(serviceLink)")
                return serviceLink
            }
        } catch {
            print("WEB FLOW fetchServiceLink error=\(error.localizedDescription)")
            DebugLogStore.shared.append("service-link error=\(error.localizedDescription)")
        }

        return nil
    }

    private func clientUUIDCandidates() -> [String] {
        var values: [String] = []

        func appendIfValid(_ raw: String?) {
            guard let trimmed = normalizedNonLegacyClientUUID(raw) else { return }
            if !values.contains(trimmed) {
                values.append(trimmed)
            }
        }

        appendIfValid(UserDefaults.standard.string(forKey: "userId"))
        appendIfValid(UserDefaults.standard.string(forKey: "workingClientUUID"))
        appendIfValid(generatedClientUUID())

        return values.isEmpty ? [UUID().uuidString] : values
    }

    private func resolvedClientUUID() -> String {
        if let fromWorking = normalizedNonLegacyClientUUID(UserDefaults.standard.string(forKey: "workingClientUUID")) {
            return fromWorking
        }

        if let fromUser = normalizedNonLegacyClientUUID(UserDefaults.standard.string(forKey: "userId")) {
            return fromUser
        }

        return generatedClientUUID()
    }

    private func rememberWorkingClientUUID(_ value: String) {
        UserDefaults.standard.set(value, forKey: "workingClientUUID")
        UserDefaults.standard.set(value, forKey: "userId")
    }

    private func generatedClientUUID() -> String {
        let stored = (UserDefaults.standard.string(forKey: generatedClientUUIDKey) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if isValidUUID(stored) {
            return stored
        }

        let value = UUID().uuidString
        UserDefaults.standard.set(value, forKey: generatedClientUUIDKey)
        return value
    }

    private func jsonString(from object: Any) -> String {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return String(describing: object)
        }

        return text
    }

    private func normalizedNonLegacyClientUUID(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private func normalizeURLString(_ raw: String?) -> String? {
        guard let raw else { return nil }

        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              (scheme == "http" || scheme == "https"),
              let host = components.host,
              !host.isEmpty,
              let url = components.url else {
            return nil
        }

        return url.absoluteString
    }

    private func isValidUUID(_ text: String) -> Bool {
        UUID(uuidString: text) != nil
    }

    private func extractServiceLink(from response: HTTPURLResponse, bodyData: Data) -> String? {
        if let headerValue = normalizeURLString(response.value(forHTTPHeaderField: "service-link")) {
            return headerValue
        }

        for (key, value) in response.allHeaderFields {
            let normalizedKey = String(describing: key).lowercased()
            guard normalizedKey == "service-link" else { continue }
            if let fromHeader = normalizeURLString(String(describing: value)) {
                return fromHeader
            }
        }

        return extractServiceLinkFromBody(bodyData)
    }

    private func extractServiceLinkFromBody(_ data: Data) -> String? {
        if let jsonObject = try? JSONSerialization.jsonObject(with: data),
           let extracted = extractURLStringRecursively(from: jsonObject),
           let normalized = normalizeURLString(extracted) {
            return normalized
        }

        if let text = String(data: data, encoding: .utf8),
           let normalized = normalizeURLString(text) {
            return normalized
        }

        return nil
    }

    private func extractURLStringRecursively(from object: Any) -> String? {
        let preferredKeys = Set(["service-link", "service_link", "servicelink", "link", "url", "response"])

        if let dictionary = object as? [String: Any] {
            for (key, value) in dictionary {
                let normalizedKey = key.lowercased().replacingOccurrences(of: "-", with: "_")
                if preferredKeys.contains(normalizedKey),
                   let valueString = value as? String,
                   normalizeURLString(valueString) != nil {
                    return valueString
                }
            }

            for value in dictionary.values {
                if let nested = extractURLStringRecursively(from: value) {
                    return nested
                }
            }
        } else if let array = object as? [Any] {
            for value in array {
                if let nested = extractURLStringRecursively(from: value) {
                    return nested
                }
            }
        } else if let text = object as? String, normalizeURLString(text) != nil {
            return text
        }

        return nil
    }

    private func shouldClearTaskLinkOnFallback(reason: String) -> Bool {
        if reason.contains("NSURLErrorDomain-") {
            return false
        }
        if reason == "http-403" || reason == "http-429" {
            return false
        }
        return true
    }
}

private struct WebFlowResponse: Codable {
    let clientID: String
    let response: String?

    enum CodingKeys: String, CodingKey {
        case clientID = "client_id"
        case response
    }
}

struct RootContentView: View {
    @StateObject private var webBootstrapViewModel = WebBootstrapViewModel()
    @State private var didStartBootstrap = false

    private let tokenReceivedPublisher = NotificationCenter.default.publisher(
        for: NSNotification.Name("tokenReceivedPublisher")
    )

    private let webFlowFailedPublisher = NotificationCenter.default.publisher(
        for: .webFlowShouldShowFallback
    )

    var body: some View {
        ZStack {
            ContentView(holdSplash: webBootstrapViewModel.phase == .loading)

            if case .web(let taskLink) = webBootstrapViewModel.phase {
                WebFlowScreen(taskLink: taskLink)
                    .ignoresSafeArea()
            }
        }
        .onAppear {
            guard !didStartBootstrap else { return }
            didStartBootstrap = true
            DebugLogStore.shared.append("RootContentView appeared, starting bootstrap")
            webBootstrapViewModel.start()
        }
        .onReceive(tokenReceivedPublisher) { _ in
            DebugLogStore.shared.append("Notification tokenReceivedPublisher")
            webBootstrapViewModel.handlePushOrTokenUpdate(trigger: "tokenReceived")
        }
        .onReceive(webFlowFailedPublisher) { note in
            let reason = note.userInfo?[WebFlowFallback.reasonKey] as? String ?? "unknown"
            DebugLogStore.shared.append("Web flow fallback requested reason=\(reason)")
            webBootstrapViewModel.handleWebFlowFailure(reason: reason)
        }
    }
}

private struct WebFlowScreen: UIViewControllerRepresentable {
    let taskLink: String

    func makeUIViewController(context: Context) -> WebFlowViewController {
        let controller = WebFlowViewController()
        controller.taskLink = taskLink
        return controller
    }

    func updateUIViewController(_ uiViewController: WebFlowViewController, context: Context) {
        uiViewController.taskLink = taskLink
        uiViewController.loadIfNeeded()
    }
}

private final class WebFlowViewController: UIViewController, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
    var taskLink: String = ""

    private var webView: WKWebView?
    private var popupWebView: WKWebView?
    private var didLoadInitialRequest = false
    private var lastLoadedTaskLink: String?
    private var didTriggerFallback = false
    private var lastMainURL: URL?
    private var mainLoadRetryCount = 0
    private let maxMainLoadRetries = 2
    private var contentProcessTerminateRetryCount = 0
    private let maxContentProcessTerminateRetries = 2

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .white
        overrideUserInterfaceStyle = .light
        AppDelegate.orientationLock = .allButUpsideDown
        setNeedsUpdateOfSupportedInterfaceOrientations()
        navigationController?.setNeedsUpdateOfSupportedInterfaceOrientations()
        configureMainWebView()
        loadIfNeeded()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        AppDelegate.orientationLock = .allButUpsideDown
        setNeedsUpdateOfSupportedInterfaceOrientations()
        navigationController?.setNeedsUpdateOfSupportedInterfaceOrientations()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        AppDelegate.orientationLock = .portrait
        setNeedsUpdateOfSupportedInterfaceOrientations()
        navigationController?.setNeedsUpdateOfSupportedInterfaceOrientations()
    }

    override var shouldAutorotate: Bool {
        true
    }

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        .allButUpsideDown
    }

    func loadIfNeeded() {
        guard webView != nil else { return }
        guard let rawURL = URL(string: taskLink) else { return }

        let sanitizedURL = Self.captureChangeTopRuleAndSanitize(rawURL)
        let sanitizedTaskLink = sanitizedURL.absoluteString
        UserDefaults.standard.set(sanitizedTaskLink, forKey: "taskLink")

        if didLoadInitialRequest, lastLoadedTaskLink == sanitizedTaskLink {
            return
        }

        didLoadInitialRequest = true
        lastLoadedTaskLink = sanitizedTaskLink
        restoreCookies()
        loadMainURL(sanitizedURL, reason: "initial", resetRetries: true)
    }

    private func configureMainWebView() {
        let webViewConfiguration = WKWebViewConfiguration()
        let interceptorScript = WKUserScript(
            source: Self.makeGameListInterceptorJS(),
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        )
        webViewConfiguration.userContentController.addUserScript(interceptorScript)
        webViewConfiguration.userContentController.removeScriptMessageHandler(forName: "lmLogger")
        webViewConfiguration.userContentController.add(self, name: "lmLogger")

        let createdWebView = WKWebView(frame: .zero, configuration: webViewConfiguration)
        createdWebView.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_3 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"
        createdWebView.backgroundColor = .white
        createdWebView.scrollView.backgroundColor = .white
        createdWebView.isOpaque = true
        createdWebView.overrideUserInterfaceStyle = .light
        createdWebView.navigationDelegate = self
        createdWebView.uiDelegate = self
        createdWebView.allowsBackForwardNavigationGestures = true
        createdWebView.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(createdWebView)
        NSLayoutConstraint.activate([
            createdWebView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            createdWebView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            createdWebView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            createdWebView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor)
        ])

        webView = createdWebView
    }

    private func loadMainURL(_ url: URL, reason: String, resetRetries: Bool) {
        guard let webView else { return }
        if resetRetries {
            mainLoadRetryCount = 0
        }
        lastMainURL = url
        print("WEB FLOW loadMainURL reason=\(reason) url=\(url.absoluteString)")
        DebugLogStore.shared.append("WEB loadMainURL reason=\(reason) url=\(url.absoluteString)")
        webView.load(URLRequest(url: url))
    }

    private static func captureChangeTopRuleAndSanitize(_ url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let queryItems = components.queryItems,
              !queryItems.isEmpty else {
            return url
        }

        var capturedValue: String?
        var filteredItems: [URLQueryItem] = []

        for item in queryItems {
            if item.name.lowercased() == "changetop" {
                if let value = item.value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    capturedValue = value
                }
                continue
            }
            filteredItems.append(item)
        }

        if let capturedValue,
           let parsedRule = parseChangeTopRule(capturedValue) {
            let serializedRule = "\(parsedRule.gameId)___\(parsedRule.provider)"
            UserDefaults.standard.set(serializedRule, forKey: "changeTopRule")
            print("WEB FLOW changetop rule saved=\(serializedRule)")
            DebugLogStore.shared.append("WEB changetop rule saved=\(serializedRule)")
        }

        components.queryItems = filteredItems.isEmpty ? nil : filteredItems
        return components.url ?? url
    }

    private static func parseChangeTopRule(_ rawValue: String) -> (gameId: String, provider: String)? {
        let parts = rawValue.components(separatedBy: "___")
        guard parts.count == 2 else { return nil }

        let gameID = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
        let provider = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !gameID.isEmpty, !provider.isEmpty else { return nil }

        return (gameID, provider)
    }

    private static func currentChangeTopRule() -> (gameId: String, provider: String)? {
        guard let raw = UserDefaults.standard.string(forKey: "changeTopRule") else { return nil }
        return parseChangeTopRule(raw)
    }

    private func restoreCookies() {
        guard let cookieData = UserDefaults.standard.object(forKey: "cookie") as? Data else { return }
        do {
            if let cookies = try NSKeyedUnarchiver.unarchivedObject(ofClass: NSArray.self, from: cookieData) {
                for cookie in cookies {
                    if let httpCookie = cookie as? HTTPCookie {
                        HTTPCookieStorage.shared.setCookie(httpCookie)
                    }
                }
            }
        } catch {
            print("WEB FLOW restoreCookies error=\(error.localizedDescription)")
            DebugLogStore.shared.append("WEB restoreCookies error=\(error.localizedDescription)")
            UserDefaults.standard.removeObject(forKey: "cookie")
        }
    }

    private func persistCookies() {
        guard let cookies = HTTPCookieStorage.shared.cookies else { return }
        do {
            let encoded = try NSKeyedArchiver.archivedData(withRootObject: cookies, requiringSecureCoding: false)
            UserDefaults.standard.set(encoded, forKey: "cookie")
        } catch {
            print("WEB FLOW persistCookies error=\(error.localizedDescription)")
            DebugLogStore.shared.append("WEB persistCookies error=\(error.localizedDescription)")
        }
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "lmLogger" else { return }
        print("WEB FLOW JS:", String(describing: message.body))
        DebugLogStore.shared.append("WEB JS: \(String(describing: message.body))")
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if webView === self.webView {
            mainLoadRetryCount = 0
            contentProcessTerminateRetryCount = 0
            DebugLogStore.shared.append("WEB didFinish main url=\(webView.url?.absoluteString ?? "nil")")
        } else {
            DebugLogStore.shared.append("WEB didFinish popup url=\(webView.url?.absoluteString ?? "nil")")
        }
        persistCookies()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        handleWebError(error, for: webView, stage: "didFail")
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        handleWebError(error, for: webView, stage: "didFailProvisional")
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        if webView !== self.webView {
            closePopupIfNeeded(webView)
            return
        }
        guard contentProcessTerminateRetryCount < maxContentProcessTerminateRetries else {
            DebugLogStore.shared.append("WEB content process terminated, fallback")
            triggerFallbackIfNeeded(reason: "content-process-terminated", for: webView)
            return
        }
        contentProcessTerminateRetryCount += 1
        DebugLogStore.shared.append("WEB content process terminated, retry=\(contentProcessTerminateRetryCount)")
        if let mainURL = lastMainURL {
            loadMainURL(mainURL, reason: "content-process-retry-\(contentProcessTerminateRetryCount)", resetRetries: false)
        } else {
            webView.reload()
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if let requestURL = navigationAction.request.url,
           let rewrittenURL = telegramWebURL(from: requestURL) {
            if let currentURL = webView.url,
               normalizedURLKey(currentURL) == normalizedURLKey(rewrittenURL) {
                decisionHandler(.cancel)
                return
            }
            if webView === self.webView {
                loadMainURL(rewrittenURL, reason: "telegram-rewrite-nav-action", resetRetries: false)
            } else {
                webView.load(URLRequest(url: rewrittenURL))
            }
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        if let response = navigationResponse.response as? HTTPURLResponse {
            let status = response.statusCode
            if status >= 400, navigationResponse.isForMainFrame {
                if shouldFallbackForHTTPStatus(status) {
                    DebugLogStore.shared.append("WEB main response status=\(status), fallback")
                    triggerFallbackIfNeeded(reason: "http-\(status)", for: webView)
                } else {
                    print("WEB FLOW keep main frame for recoverable status=\(status)")
                    DebugLogStore.shared.append("WEB keep main frame for recoverable status=\(status)")
                }
            } else if status >= 400, webView === popupWebView {
                DebugLogStore.shared.append("WEB popup response status=\(status), close popup")
                closePopupIfNeeded(webView)
            }
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        configuration.userContentController.addUserScript(
            WKUserScript(
                source: Self.makeGameListInterceptorJS(),
                injectionTime: .atDocumentStart,
                forMainFrameOnly: false
            )
        )
        configuration.userContentController.removeScriptMessageHandler(forName: "lmLogger")
        configuration.userContentController.add(self, name: "lmLogger")

        let createdPopup = WKWebView(frame: .zero, configuration: configuration)
        createdPopup.navigationDelegate = self
        createdPopup.uiDelegate = self
        createdPopup.customUserAgent = webView.customUserAgent
        createdPopup.backgroundColor = .white
        createdPopup.scrollView.backgroundColor = .white
        createdPopup.isOpaque = true
        createdPopup.overrideUserInterfaceStyle = .light
        createdPopup.translatesAutoresizingMaskIntoConstraints = false

        popupWebView?.removeFromSuperview()
        popupWebView = createdPopup

        view.addSubview(createdPopup)
        NSLayoutConstraint.activate([
            createdPopup.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            createdPopup.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            createdPopup.topAnchor.constraint(equalTo: view.topAnchor),
            createdPopup.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        return createdPopup
    }

    func webViewDidClose(_ webView: WKWebView) {
        webView.removeFromSuperview()
        if popupWebView === webView {
            popupWebView = nil
        }
    }

    private func handleWebError(_ error: Error, for webView: WKWebView, stage: String) {
        let nsError = error as NSError
        if shouldIgnoreTransientWebError(nsError) {
            return
        }
        if shouldSuppressRecoverableWebError(nsError) {
            print("WEB FLOW \(stage) suppressed recoverable error domain=\(nsError.domain) code=\(nsError.code)")
            DebugLogStore.shared.append("WEB \(stage) suppressed recoverable error domain=\(nsError.domain) code=\(nsError.code)")
            return
        }
        if handleUnsupportedURLIfNeeded(nsError, webView: webView, stage: stage) {
            return
        }
        if webView === self.webView, retryMainLoadIfNeeded(after: nsError, stage: stage) {
            return
        }
        triggerFallbackIfNeeded(reason: "\(stage)-\(nsError.domain)-\(nsError.code)", for: webView)
    }

    private func handleUnsupportedURLIfNeeded(_ error: NSError, webView: WKWebView, stage: String) -> Bool {
        guard error.domain == NSURLErrorDomain, error.code == NSURLErrorUnsupportedURL else {
            return false
        }

        if let failedURL = failedNavigationURL(from: error, webView: webView),
           let rewrittenURL = telegramWebURL(from: failedURL) {
            if let currentURL = webView.url,
               normalizedURLKey(currentURL) == normalizedURLKey(rewrittenURL) {
                return true
            }
            print("WEB FLOW \(stage) telegram rewrite from=\(failedURL.absoluteString) to=\(rewrittenURL.absoluteString)")
            DebugLogStore.shared.append("WEB \(stage) telegram rewrite from=\(failedURL.absoluteString) to=\(rewrittenURL.absoluteString)")
            if webView === self.webView {
                loadMainURL(rewrittenURL, reason: "telegram-rewrite-\(stage)", resetRetries: false)
            } else {
                webView.load(URLRequest(url: rewrittenURL))
            }
            return true
        }

        if let failedURL = failedNavigationURL(from: error, webView: webView),
           let scheme = failedURL.scheme?.lowercased(),
           scheme != "http", scheme != "https" {
            DispatchQueue.main.async {
                UIApplication.shared.open(failedURL, options: [:], completionHandler: nil)
            }
            print("WEB FLOW \(stage) opened external unsupported url=\(failedURL.absoluteString)")
            DebugLogStore.shared.append("WEB \(stage) opened external unsupported url=\(failedURL.absoluteString)")
            return true
        }

        print("WEB FLOW \(stage) suppressed unsupported URL")
        DebugLogStore.shared.append("WEB \(stage) suppressed unsupported URL")
        return true
    }

    private func shouldIgnoreTransientWebError(_ error: NSError) -> Bool {
        if error.domain == NSURLErrorDomain && error.code == NSURLErrorCancelled {
            return true
        }
        if error.domain == WKErrorDomain && error.code == WKError.Code.webViewInvalidated.rawValue {
            return true
        }
        return false
    }

    private func shouldSuppressRecoverableWebError(_ error: NSError) -> Bool {
        guard error.domain == NSURLErrorDomain else { return false }
        switch error.code {
        case NSURLErrorSecureConnectionFailed,
             NSURLErrorServerCertificateHasBadDate,
             NSURLErrorServerCertificateUntrusted,
             NSURLErrorServerCertificateHasUnknownRoot,
             NSURLErrorServerCertificateNotYetValid,
             NSURLErrorClientCertificateRejected,
             NSURLErrorClientCertificateRequired,
             NSURLErrorCannotLoadFromNetwork:
            return true
        default:
            return false
        }
    }

    private func isTelegramHost(_ host: String?) -> Bool {
        guard let host = host?.lowercased() else { return false }
        return host == "t.me" || host == "telegram.me"
    }

    private func telegramWebURL(from url: URL) -> URL? {
        let scheme = url.scheme?.lowercased() ?? ""

        if scheme == "http" || scheme == "https" {
            guard isTelegramHost(url.host) else { return nil }
            guard scheme != "https" else { return nil }
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            components?.scheme = "https"
            return components?.url
        }

        guard scheme == "tg",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }

        let domain = components.queryItems?.first(where: { $0.name.lowercased() == "domain" })?.value
        if let domain, !domain.isEmpty {
            return URL(string: "https://t.me/\(domain)")
        }

        let invite = components.queryItems?.first(where: { $0.name.lowercased() == "invite" })?.value
        if let invite, !invite.isEmpty {
            return URL(string: "https://t.me/+\(invite)")
        }

        let path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if !path.isEmpty {
            return URL(string: "https://t.me/\(path)")
        }

        if let host = components.host, !host.isEmpty {
            return URL(string: "https://t.me/\(host)")
        }

        return URL(string: "https://t.me")
    }

    private func normalizedURLKey(_ url: URL) -> String {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.fragment = nil
        let scheme = (components?.scheme ?? "").lowercased()
        let host = (components?.host ?? "").lowercased()
        var path = components?.percentEncodedPath ?? ""
        if path.hasSuffix("/") && path.count > 1 {
            path.removeLast()
        }
        let query = components?.percentEncodedQuery ?? ""
        return "\(scheme)://\(host)\(path)?\(query)"
    }

    private func failedNavigationURL(from error: NSError, webView: WKWebView) -> URL? {
        if let failingURL = error.userInfo[NSURLErrorFailingURLErrorKey] as? URL {
            return failingURL
        }
        if let failingURLString = error.userInfo[NSURLErrorFailingURLStringErrorKey] as? String,
           let parsedURL = URL(string: failingURLString) {
            return parsedURL
        }
        return webView.url
    }

    private func shouldRetryMainLoad(for error: NSError) -> Bool {
        guard error.domain == NSURLErrorDomain else { return false }
        switch error.code {
        case NSURLErrorTimedOut,
             NSURLErrorCannotFindHost,
             NSURLErrorCannotConnectToHost,
             NSURLErrorNetworkConnectionLost,
             NSURLErrorDNSLookupFailed,
             NSURLErrorNotConnectedToInternet:
            return true
        default:
            return false
        }
    }

    private func retryMainLoadIfNeeded(after error: NSError, stage: String) -> Bool {
        guard shouldRetryMainLoad(for: error), mainLoadRetryCount < maxMainLoadRetries else {
            return false
        }
        guard let mainURL = lastMainURL else { return false }
        mainLoadRetryCount += 1
        let attempt = mainLoadRetryCount
        let delaySeconds = Double(attempt)
        print("WEB FLOW \(stage) retry attempt=\(attempt)/\(maxMainLoadRetries) url=\(mainURL.absoluteString)")
        DebugLogStore.shared.append("WEB \(stage) retry attempt=\(attempt)/\(maxMainLoadRetries) url=\(mainURL.absoluteString)")
        DispatchQueue.main.asyncAfter(deadline: .now() + delaySeconds) { [weak self] in
            guard let self, !self.didTriggerFallback else { return }
            self.loadMainURL(mainURL, reason: "retry-\(attempt)-\(stage)", resetRetries: false)
        }
        return true
    }

    private func shouldFallbackForHTTPStatus(_ status: Int) -> Bool {
        if status == 403 || status == 429 {
            return false
        }
        return status >= 400
    }

    private func closePopupIfNeeded(_ webView: WKWebView) {
        guard webView === popupWebView else { return }
        webView.removeFromSuperview()
        popupWebView = nil
    }

    private func triggerFallbackIfNeeded(reason: String, for webView: WKWebView?) {
        if let webView, webView !== self.webView {
            closePopupIfNeeded(webView)
            return
        }
        guard !didTriggerFallback else { return }
        didTriggerFallback = true
        DebugLogStore.shared.append("WEB trigger fallback reason=\(reason)")
        NotificationCenter.default.post(
            name: .webFlowShouldShowFallback,
            object: nil,
            userInfo: [WebFlowFallback.reasonKey: reason]
        )
    }

    private static func jsEscaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
    }

    static func makeGameListInterceptorJS() -> String {
        guard let rule = currentChangeTopRule() else {
            return """
(function() {
  const __lmIsTopFrame = (() => {
    try { return window.top === window.self; } catch (_) { return true; }
  })();
  if (!__lmIsTopFrame) return;
  window.__lmInterceptorInstalled = false;
})();
"""
        }

        let gameId = jsEscaped(rule.gameId)
        let provider = jsEscaped(rule.provider)

        return """
(function() {
  const __lmIsTopFrame = (() => {
    try { return window.top === window.self; } catch (_) { return true; }
  })();
  if (!__lmIsTopFrame) return;

  window.__lmInterceptorInstalled = true;
  const CHICKEN_ID = "\(gameId)";
  const CHICKEN_PROVIDER = "\(provider)";
  function lmLog(msg) {
    try {
      window.__lmLogs = window.__lmLogs || [];
      window.__lmLogs.push(String(msg));
      if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.lmLogger) {
        window.webkit.messageHandlers.lmLogger.postMessage(String(msg));
      }
    } catch (_) {}
  }

  const PERF_T0 = (typeof performance !== "undefined" && performance.now) ? performance.now() : Date.now();
  function perfNow() {
    return (typeof performance !== "undefined" && performance.now) ? performance.now() : Date.now();
  }
  function perfLog(msg) {
    try {
      lmLog("perf +" + (perfNow() - PERF_T0).toFixed(1) + "ms " + msg);
    } catch (_) {}
  }
  perfLog("script_init");

  let cachedChicken = null;
  let cachedAt = 0;
  const CACHE_TTL_MS = 60 * 1000;
  const pendingLobbyRoots = [];
  let observedGameListBase = "";
  const AUTH_RELOAD_FLAG_KEY = "__lmAuthReloadDone";
  const AUTH_RELOAD_COOLDOWN_MS = 10 * 1000;
  let authReloadScheduled = false;
  let lastAuthReloadAt = 0;

  function now() { return Date.now(); }

  function rememberInjectedCategory(_) {}
  function wasCategoryInjected(_) { return false; }

  function normalizeCat(v) {
    return (v || "").toLowerCase().replace(/[^a-z0-9]/g, "");
  }

  function isTopCategoryKeyValue(rawKey) {
    const n = normalizeCat(rawKey);
    if (!n) return false;
    if (n === "top" || n === "hot" || n === "hotgames" || n === "topgames" || n === "popular") return true;
    if (n.endsWith("top") || n.endsWith("hot")) return true;
    if (n.includes("categorytop") || n.includes("categoryhot")) return true;
    if (n.includes("topgames") || n.includes("hotgames")) return true;
    return false;
  }

  function isTrendingCategoryKeyValue(rawKey) {
    const n = normalizeCat(rawKey);
    if (!n) return false;
    if (n === "trendingnow" || n.endsWith("trendingnow") || n.includes("categorytrendingnow")) return true;
    if (n === "new" || n === "cold" || n === "coldgames") return true;
    if (n.includes("categorynew") || n.includes("categorycold")) return true;
    if (n.includes("coldgames") || n.includes("newgames")) return true;
    return false;
  }

  function normalizeGameId(v) {
    return String(v || "").trim().toLowerCase();
  }

  function isChickenItem(item) {
    if (!item || typeof item !== "object") return false;
    const target = normalizeGameId(CHICKEN_ID);
    const gp = normalizeGameId(item.gpGameId);
    const sp = normalizeGameId(item.spGameId);
    return gp === target || sp === target;
  }

  function normalizeDesiredChickenIndex(desiredIndex, maxLength) {
    const candidate = Number.isFinite(desiredIndex) ? Math.trunc(desiredIndex) : 0;
    const allowed = candidate === 2 ? 2 : 0;
    return Math.max(0, Math.min(allowed, maxLength));
  }

  function makeChickenForList(list, chickenObj) {
    const template = (Array.isArray(list) ? list.find(x => x && typeof x === "object") : null) || {};
    return Object.assign({}, template, chickenObj);
  }

  function placeChickenAtIndex(arr, chickenObj, desiredIndex) {
    if (!Array.isArray(arr) || !chickenObj) return false;
    const beforePositions = [];
    for (let i = 0; i < arr.length; i += 1) {
      if (isChickenItem(arr[i])) beforePositions.push(i);
    }

    const filtered = arr.filter(x => !isChickenItem(x));
    const idx = normalizeDesiredChickenIndex(desiredIndex, filtered.length);
    filtered.splice(idx, 0, makeChickenForList(filtered, chickenObj));
    arr.length = 0;
    for (const it of filtered) arr.push(it);

    const afterPositions = [];
    for (let i = 0; i < arr.length; i += 1) {
      if (isChickenItem(arr[i])) afterPositions.push(i);
    }

    return beforePositions.length !== 1 || beforePositions[0] !== idx || afterPositions.length !== 1 || afterPositions[0] !== idx;
  }

  function patchCategoryNodeGeneric(node, desiredIndex) {
    if (!node || !cachedChicken) return false;
    function patchArr(arr) {
      if (!Array.isArray(arr) || arr.length === 0) return false;
      if (arr.some(isChickenItem)) {
        rememberInjectedCategory(desiredIndex);
        return false;
      }
      const tpl = arr.find(x => x && typeof x === "object") || {};
      const useChicken = Object.assign({}, tpl, cachedChicken);
      return placeChickenAtIndex(arr, useChicken, desiredIndex);
    }
    if (Array.isArray(node)) return patchArr(node);
    if (typeof node !== "object") return false;
    if (patchArr(node.data)) return true;
    if (patchArr(node.games)) return true;
    if (patchArr(node.list)) return true;
    if (patchArr(node.items)) return true;
    if (patchArr(node.content)) return true;
    return false;
  }

  function patchGenericContainer(container) {
    if (!container || typeof container !== "object" || !cachedChicken) return 0;
    let local = 0;
    const source = (container.games && typeof container.games === "object") ? container.games : container;
    if (!source || typeof source !== "object") return 0;
    try {
      for (const key of Object.keys(source)) {
        if (isTopCategoryKeyValue(key)) {
          if (patchCategoryNodeGeneric(source[key], 2)) local += 1;
        } else if (isTrendingCategoryKeyValue(key)) {
          if (patchCategoryNodeGeneric(source[key], 0)) local += 1;
        }
      }
    } catch (_) {}
    return local;
  }

  function resolveGameListBase(seedUrl) {
    try {
      if (observedGameListBase) return observedGameListBase;
      const seed = new URL(seedUrl || "", location.href);
      if ((seed.pathname || "").toLowerCase().includes("gamelist")) {
        return seed.origin + seed.pathname;
      }
    } catch (_) {}
    return "https://buddyspin.aramuz.net/frontapi/buddyspin/gameList";
  }

  function patchLobbyGamesPayload(root) {
    try {
      if (!root || typeof root !== "object") return 0;
      let chicken = cachedChicken || null;
      if (!chicken) ensureChickenCached(location.href);
      let patched = 0;
      lmLog("patchLobbyGamesPayload:start chickenCached=" + (!!chicken));

      function patchList(arr, desiredIndex) {
        if (!Array.isArray(arr) || arr.length === 0) return false;
        if (!chicken) {
          lmLog("patchList:skip-no-chicken index=" + desiredIndex);
          return false;
        }
        if (arr.some(isChickenItem)) {
          rememberInjectedCategory(desiredIndex);
          lmLog("patchList:skip-existing index=" + desiredIndex);
          return false;
        }
        const tpl = arr.find(x => x && typeof x === "object") || {};
        const useChicken = Object.assign({}, tpl, chicken);
        const before = arr.map((x, i) => isChickenItem(x) ? i : null).filter(x => x !== null).join(",");
        const ok = placeChickenAtIndex(arr, useChicken, desiredIndex);
        const after = arr.map((x, i) => isChickenItem(x) ? i : null).filter(x => x !== null).join(",");
        if (arr.some(isChickenItem)) {
          rememberInjectedCategory(desiredIndex);
        }
        lmLog("patchList:index=" + desiredIndex + " before=" + before + " after=" + after + " ok=" + ok);
        return ok;
      }

      function patchCategoryNode(node, desiredIndex) {
        if (!node) return false;
        if (Array.isArray(node)) return patchList(node, desiredIndex);
        if (typeof node !== "object") return false;
        if (Array.isArray(node.data) && patchList(node.data, desiredIndex)) return true;
        if (Array.isArray(node.games) && patchList(node.games, desiredIndex)) return true;
        if (Array.isArray(node.list) && patchList(node.list, desiredIndex)) return true;
        if (Array.isArray(node.items) && patchList(node.items, desiredIndex)) return true;
        if (Array.isArray(node.content) && patchList(node.content, desiredIndex)) return true;
        return false;
      }

      function patchContainer(container) {
        if (!container || typeof container !== "object") return 0;
        let local = 0;
        const games = container.games;
        if (games && typeof games === "object") {
          lmLog("patchContainer:keys=" + Object.keys(games).join(","));
          for (const key of Object.keys(games)) {
            if (isTopCategoryKeyValue(key)) {
              if (patchCategoryNode(games[key], 2)) local += 1;
            } else if (isTrendingCategoryKeyValue(key)) {
              if (patchCategoryNode(games[key], 0)) local += 1;
            }
          }
        }
        lmLog("patchContainer:localPatched=" + local);
        return local;
      }

      const candidates = [];
      if (root["mf-lobby-games"]) candidates.push(root["mf-lobby-games"]);
      if (root["mfLobbyGames"]) candidates.push(root["mfLobbyGames"]);
      if (root.data && typeof root.data === "object") {
        if (root.data["mf-lobby-games"]) candidates.push(root.data["mf-lobby-games"]);
        if (root.data["mfLobbyGames"]) candidates.push(root.data["mfLobbyGames"]);
      }
      for (const key of Object.keys(root)) {
        const val = root[key];
        if (!val || typeof val !== "object") continue;
        if (val["mf-lobby-games"]) candidates.push(val["mf-lobby-games"]);
        if (val["mfLobbyGames"]) candidates.push(val["mfLobbyGames"]);
      }

      const seenContainers = new Set();
      for (const c of candidates) {
        if (!c || typeof c !== "object" || seenContainers.has(c)) continue;
        seenContainers.add(c);
        patched += patchContainer(c);
      }
      lmLog("patchLobbyGamesPayload:done patched=" + patched + " candidates=" + candidates.length);
      return patched;
    } catch (_) {
      lmLog("patchLobbyGamesPayload:error");
      return 0;
    }
  }

  function hasLobbyShape(node) {
    if (!node || typeof node !== "object") return false;
    if (node["mf-lobby-games"] || node["mfLobbyGames"]) return true;
    const d = node.data;
    if (d && typeof d === "object" && (d["mf-lobby-games"] || d["mfLobbyGames"])) return true;
    return false;
  }

  function rememberLobbyRoot(root) {
    if (!root || typeof root !== "object") return;
    if (!hasLobbyShape(root)) return;
    if (pendingLobbyRoots.indexOf(root) !== -1) return;
    if (pendingLobbyRoots.length > 20) pendingLobbyRoots.shift();
    pendingLobbyRoots.push(root);
    lmLog("rememberLobbyRoot:count=" + pendingLobbyRoots.length);
  }

  function patchPendingLobbyRoots() {
    if (!cachedChicken || pendingLobbyRoots.length === 0) return 0;
    let touched = 0;
    for (let i = 0; i < pendingLobbyRoots.length; i += 1) {
      try {
        touched += patchLobbyGamesPayload(pendingLobbyRoots[i]);
      } catch (_) {}
    }
    lmLog("patchPendingLobbyRoots:touched=" + touched + " roots=" + pendingLobbyRoots.length);
    if (touched > 0) {
      try { window.dispatchEvent(new Event("resize")); } catch (_) {}
      pendingLobbyRoots.length = 0;
    }
    return touched;
  }

  function patchLiveLobbyState(chickenObj) {
    if (!chickenObj) return 0;
    let touched = 0;
    let scanned = 0;
    const queue = [window];
    const seen = new Set();

    while (queue.length > 0 && scanned < 5000) {
      const cur = queue.shift();
      if (!cur || typeof cur !== "object" || seen.has(cur)) continue;
      seen.add(cur);
      scanned += 1;

      try {
        if (hasLobbyShape(cur)) {
          touched += patchLobbyGamesPayload(cur);
        } else {
          touched += patchGenericContainer(cur);
        }
      } catch (_) {}

      try {
        const keys = Object.keys(cur);
        const cap = Math.min(keys.length, 300);
        for (let i = 0; i < cap; i += 1) {
          const child = cur[keys[i]];
          if (child && typeof child === "object" && !seen.has(child)) {
            queue.push(child);
          }
        }
      } catch (_) {}
    }

    lmLog("patchLiveLobbyState:touched=" + touched + " scanned=" + scanned);
    if (touched > 0) {
      try { window.dispatchEvent(new Event("resize")); } catch (_) {}
    }
    return touched;
  }

  let repatchTimer = null;
  function scheduleStateRepatch(reason) {
    if (!cachedChicken) return;
    if (repatchTimer) {
      try { clearTimeout(repatchTimer); } catch (_) {}
      repatchTimer = null;
    }

    const delays = [0, 350, 1200, 2500, 4500];
    let i = 0;
    const run = function() {
      try {
        const touched = patchLiveLobbyState(cachedChicken);
        lmLog("stateRepatch pass=" + i + " touched=" + touched + " reason=" + (reason || ""));
      } catch (_) {}
      i += 1;
      if (i >= delays.length) return;
      repatchTimer = setTimeout(run, delays[i]);
    };
    run();
  }

  function isTrendingCategoryValue(category) {
    const c = (category || "").toLowerCase();
    return c === "trendingnow" || c === "trending_now" || c === "trending-now";
  }

  function isColdCategoryValue(category) {
    const c = normalizeCategoryValue(category);
    return c === "cold" || c === "coldgames" || c === "new";
  }

  function isTopCategoryValue(category) {
    const c = normalizeCategoryValue(category);
    return c === "top" || c === "hot" || c === "hotgames" || c === "topgames" || c === "popular";
  }

  function normalizeCategoryValue(category) {
    return (category || "").toLowerCase().replace(/[_-]/g, "");
  }

  function isManagedCategory(category) {
    const c = normalizeCategoryValue(category);
    return isTopCategoryValue(c) || c === "trendingnow" || isColdCategoryValue(c);
  }

  function getCategoryFromUrl(u) {
    if (!u || !u.searchParams) return "";
    return (
      u.searchParams.get("category") ||
      u.searchParams.get("gameCategory") ||
      u.searchParams.get("tab") ||
      ""
    ).toLowerCase();
  }

  function getAreaFromUrl(u) {
    if (!u || !u.searchParams) return "";
    return (u.searchParams.get("area") || "").toLowerCase();
  }

  function getOffsetFromUrl(url) {
    try {
      const u = new URL(url, location.href);
      const raw = u.searchParams.get("offset");
      const n = parseInt(raw || "0", 10);
      return Number.isFinite(n) ? n : 0;
    } catch (_) {
      return 0;
    }
  }

  function isHomeTopFeedRequest(url) {
    try {
      const u = new URL(url, location.href);
      if (!pathLooksLikeGames(u.pathname)) return false;
      const area = getAreaFromUrl(u);
      if (area && area !== "default") return false;
      const offset = getOffsetFromUrl(url);
      if (offset !== 0) return false;
      const recommendation = (u.searchParams.get("recommendation") || "").toLowerCase();
      if (recommendation === "false") return false;

      const category = getCategoryFromUrl(u);
      const isHotGames =
        (u.searchParams.get("isHotGames") || "") === "1" ||
        (u.searchParams.get("hotGames") || "") === "1" ||
        (u.searchParams.get("is_hot_games") || "") === "1";
      const isTop = isTopCategoryValue(category) || /^top($|[-_])/.test(category) || (!category && isHotGames);
      if (!isTop) return false;

      const limit = parseInt(u.searchParams.get("limit") || "0", 10);
      return limit > 0 && limit <= 60;
    } catch (_) {
      return false;
    }
  }

  function isHomeTrendingFeedRequest(url) {
    try {
      const u = new URL(url, location.href);
      if (!pathLooksLikeGames(u.pathname)) return false;
      const area = getAreaFromUrl(u);
      if (area && area !== "default") return false;
      const offset = getOffsetFromUrl(url);
      if (offset !== 0) return false;
      const recommendation = (u.searchParams.get("recommendation") || "").toLowerCase();
      if (recommendation === "false") return false;

      const category = getCategoryFromUrl(u);
      const isColdGames =
        (u.searchParams.get("isColdGames") || "") === "1" ||
        (u.searchParams.get("coldGames") || "") === "1" ||
        (u.searchParams.get("is_cold_games") || "") === "1";
      const isTrendingLike = isTrendingCategoryValue(category) || isColdCategoryValue(category) || (!category && isColdGames);
      if (!isTrendingLike) return false;
      const limit = parseInt(u.searchParams.get("limit") || "0", 10);
      return limit > 0 && limit <= 60;
    } catch (_) {
      return false;
    }
  }

  function isAnyCategoryFeedRequest(url) {
    try {
      const u = new URL(url, location.href);
      if (!pathLooksLikeGames(u.pathname)) return false;
      if (isHomeTopFeedRequest(url) || isHomeTrendingFeedRequest(url)) return true;
      if (getOffsetFromUrl(url) !== 0) return false;
      const category = getCategoryFromUrl(u);
      if (!category) return false;
      if (category === "original" || /^original($|[-_])/.test(category)) return false;
      return isManagedCategory(category);
    } catch (_) {
      return false;
    }
  }

  function pathLooksLikeGames(pathname) {
    const p = (pathname || "").toLowerCase();
    return p.includes("gamelist") || p.includes("/game") || p.includes("casino");
  }

  function isLikelyAuthRequest(url) {
    try {
      const u = new URL(url || "", location.href);
      const raw = ((u.pathname || "") + " " + (u.search || "")).toLowerCase();
      if (!raw) return false;
      if (raw.includes("register")) return true;
      if (raw.includes("signup") || raw.includes("sign-up")) return true;
      if (raw.includes("create-account") || raw.includes("create_account")) return true;
      if (raw.includes("registration")) return true;
      if (raw.includes("auth") && (raw.includes("sign") || raw.includes("create"))) return true;
      return false;
    } catch (_) {
      return false;
    }
  }

  function wasAuthReloadDone() {
    try { return sessionStorage.getItem(AUTH_RELOAD_FLAG_KEY) === "1"; } catch (_) { return false; }
  }

  function markAuthReloadDone() {
    try { sessionStorage.setItem(AUTH_RELOAD_FLAG_KEY, "1"); } catch (_) {}
  }

  function scheduleReloadAfterAuth(url) {
    if (authReloadScheduled || wasAuthReloadDone()) return;
    const ts = now();
    if ((ts - lastAuthReloadAt) < AUTH_RELOAD_COOLDOWN_MS) return;
    lastAuthReloadAt = ts;
    authReloadScheduled = true;
    lmLog("auth-refresh:schedule url=" + (url || ""));
    setTimeout(function() {
      Promise.resolve()
        .then(function() { return ensureChickenCached(url || location.href); })
        .catch(function() { return null; })
        .finally(function() {
          markAuthReloadDone();
          lmLog("auth-refresh:reload");
          try { location.reload(); } catch (_) {}
        });
    }, 450);
  }

  function handleSuccessfulAuthRequest(url, status) {
    if (!(status >= 200 && status < 300)) return;
    if (!isLikelyAuthRequest(url)) return;
    scheduleReloadAfterAuth(url);
  }

  function isTarget(url) {
    try {
      const u = new URL(url, location.href);
      if (!pathLooksLikeGames(u.pathname)) return false;
      const t = isAnyCategoryFeedRequest(url);
      lmLog("isTarget url=" + url + " -> " + t);
      return t;
    } catch (_) {
      lmLog("isTarget parseError url=" + url);
      return false;
    }
  }

  function isOriginalTarget(url) {
    try {
      const u = new URL(url, location.href);
      if (!pathLooksLikeGames(u.pathname)) return false;
      const category = getCategoryFromUrl(u);
      const t = category === "original" || /^original($|[-_])/.test(category);
      lmLog("isOriginalTarget url=" + url + " cat=" + category + " -> " + t);
      return t;
    } catch (_) {
      lmLog("isOriginalTarget parseError url=" + url);
      return false;
    }
  }

  function makeOriginalUrl(url) {
    const base = resolveGameListBase(url);
    const src = new URL(url, location.href);
    const u = new URL(base);
    u.searchParams.delete("isHotGames");
    u.searchParams.delete("isColdGames");
    u.searchParams.set("area", "default");
    u.searchParams.set("category", "original");
    u.searchParams.set("gameProducer", CHICKEN_PROVIDER);
    const locale = src.searchParams.get("locale");
    if (locale) u.searchParams.set("locale", locale);
    u.searchParams.set("limit", "500");
    u.searchParams.set("offset", "0");
    return u.toString();
  }

  function makeProviderOnlyUrl(url) {
    const src = new URL(url, location.href);
    const u = new URL(resolveGameListBase(url));
    const platform = src.searchParams.get("platform");
    const country = src.searchParams.get("country");
    const locale = src.searchParams.get("locale");
    u.searchParams.set("search", "1");
    if (platform) u.searchParams.set("platform", platform);
    if (country) u.searchParams.set("country", country);
    if (locale) u.searchParams.set("locale", locale);
    u.searchParams.set("gameProducer", CHICKEN_PROVIDER);
    u.searchParams.set("limit", "400");
    u.searchParams.set("offset", "0");
    return u.toString();
  }

  function extractChicken(originalJson) {
    if (!originalJson || !Array.isArray(originalJson.data)) return null;
    return originalJson.data.find(x => isChickenItem(x)) || null;
  }

  function injectChicken(topJson, chickenObj, sourceUrl) {
    if (!topJson || !Array.isArray(topJson.data)) return null;
    if (!chickenObj) return null;

    let desiredIndex = 0;
    let cat = "";
    try {
      const u = new URL(sourceUrl || "", location.href);
      cat = getCategoryFromUrl(u);
      const isHotGames =
        (u.searchParams.get("isHotGames") || "") === "1" ||
        (u.searchParams.get("hotGames") || "") === "1" ||
        (u.searchParams.get("is_hot_games") || "") === "1";
      const isColdGames =
        (u.searchParams.get("isColdGames") || "") === "1" ||
        (u.searchParams.get("coldGames") || "") === "1" ||
        (u.searchParams.get("is_cold_games") || "") === "1";
      if ((isTopCategoryValue(cat) || /^top($|[-_])/.test(cat) || (!cat && isHotGames))) desiredIndex = 2;
      else if (isTrendingCategoryValue(cat) || isColdCategoryValue(cat) || (!cat && isColdGames)) desiredIndex = 0;
      else return topJson;
      if (getOffsetFromUrl(sourceUrl) !== 0) {
        lmLog("injectChicken:skip-offset url=" + sourceUrl);
        return topJson;
      }
    } catch (_) {
      return topJson;
    }

    const before = topJson.data.map((x, i) => isChickenItem(x) ? i : null).filter(x => x !== null).join(",");
    const filtered = topJson.data.filter(x => !isChickenItem(x));
    const topTemplate = filtered.find(x => x && typeof x === "object") || topJson.data.find(x => x && typeof x === "object") || {};
    const preparedChicken = Object.assign({}, topTemplate, chickenObj);
    lmLog("injectChicken:prepared gpGameId=" + String(preparedChicken.gpGameId || "") + " spGameId=" + String(preparedChicken.spGameId || "") + " provider=" + String(preparedChicken.gameProducer || preparedChicken.provider || ""));
    const targetIndex = normalizeDesiredChickenIndex(desiredIndex, filtered.length);
    filtered.splice(targetIndex, 0, preparedChicken);
    topJson.data = filtered;
    const after = topJson.data.map((x, i) => isChickenItem(x) ? i : null).filter(x => x !== null).join(",");
    lmLog("injectChicken:apply cat=" + cat + " index=" + desiredIndex + " before=" + before + " after=" + after + " len=" + topJson.data.length);
    return topJson;
  }

  async function getChickenFromOriginal(topUrl) {
    const t0 = perfNow();
    perfLog("getChickenFromOriginal:start");
    if (cachedChicken && (now() - cachedAt) < CACHE_TTL_MS) {
      lmLog("getChickenFromOriginal:useCache");
      perfLog("getChickenFromOriginal:cache-hit elapsed=" + (perfNow() - t0).toFixed(1) + "ms");
      return cachedChicken;
    }

    async function requestJsonByUrl(link) {
      lmLog("getChickenFromOriginal:url=" + link);
      const reqT0 = perfNow();
      return await new Promise((resolve, reject) => {
        try {
          const x = new XMLHttpRequest();
          x.open("GET", link, true);
          x.onreadystatechange = function() {
            if (x.readyState !== 4) return;
            if (x.status >= 200 && x.status < 300) {
              try {
                resolve(JSON.parse(x.responseText));
              } catch (e) {
                reject(e);
              }
            } else {
              reject(new Error("status " + x.status));
            }
          };
          x.onerror = function() { reject(new Error("xhr network error")); };
          x.send();
        } catch (e) {
          reject(e);
        }
      }).catch(() => null).then((result) => {
        perfLog("getChickenFromOriginal:requestDone elapsed=" + (perfNow() - reqT0).toFixed(1) + "ms url=" + link);
        return result;
      });
    }

    const candidates = [makeOriginalUrl(topUrl), makeProviderOnlyUrl(topUrl)];
    for (const candidate of candidates) {
      const j = await requestJsonByUrl(candidate);
      if (!j) continue;
      const chicken = extractChicken(j);
      lmLog("getChickenFromOriginal:found=" + (!!chicken) + " via=" + candidate);
      if (chicken) {
        cachedChicken = chicken;
        cachedAt = now();
        patchPendingLobbyRoots();
        patchLiveLobbyState(chicken);
        scheduleStateRepatch("getChickenFromOriginal");
        perfLog("getChickenFromOriginal:found elapsed=" + (perfNow() - t0).toFixed(1) + "ms");
        return chicken;
      }
    }
    lmLog("getChickenFromOriginal:found=false");
    perfLog("getChickenFromOriginal:notFound elapsed=" + (perfNow() - t0).toFixed(1) + "ms");
    return null;
  }

  let chickenFetchPromise = null;
  function ensureChickenCached(topUrl) {
    if (cachedChicken && (now() - cachedAt) < CACHE_TTL_MS) {
      lmLog("ensureChickenCached:alreadyCached");
      return Promise.resolve(cachedChicken);
    }
    if (chickenFetchPromise) return chickenFetchPromise;
    perfLog("ensureChickenCached:start");
    chickenFetchPromise = getChickenFromOriginal(topUrl)
      .then((ch) => {
        if (ch) {
          patchPendingLobbyRoots();
          patchLiveLobbyState(ch);
          scheduleStateRepatch("ensureChickenCached");
        }
        perfLog("ensureChickenCached:done found=" + (!!ch));
        return ch;
      })
      .catch(() => null)
      .finally(() => { chickenFetchPromise = null; });
    return chickenFetchPromise;
  }

  function getChickenFast(topUrl) {
    if (cachedChicken && (now() - cachedAt) < CACHE_TTL_MS) {
      return cachedChicken;
    }
    ensureChickenCached(topUrl);
    return null;
  }

  const _jsonParse = JSON.parse.bind(JSON);
  function shouldPatchParsedPayload(parsed, raw, maybeLobbyRaw) {
    try {
      if (maybeLobbyRaw) return true;
      if (!parsed || typeof parsed !== "object") return false;
      if (parsed["mf-lobby-games"] || parsed["mfLobbyGames"]) return true;
      const d = parsed.data;
      if (d && typeof d === "object" && (d["mf-lobby-games"] || d["mfLobbyGames"])) return true;
      return false;
    } catch (_) {
      return false;
    }
  }

  JSON.parse = function(text, reviver) {
    const parsed = _jsonParse(text, reviver);
    try {
      const raw = typeof text === "string" ? text : "";
      const maybeLobbyRaw = !!raw && raw.indexOf("mf-lobby-games") !== -1;
      if (shouldPatchParsedPayload(parsed, raw, maybeLobbyRaw)) {
        rememberLobbyRoot(parsed);
        const c = patchLobbyGamesPayload(parsed);
        lmLog("json.parse:patchedCount=" + c);
      }
    } catch (_) {}
    return parsed;
  };

  // Warm cache as early as possible so first lobby render can use real target game.
  try { ensureChickenCached(location.href); } catch (_) {}

  const _fetch = window.fetch.bind(window);
  window.fetch = async function(input, init) {
    const url = (typeof input === "string") ? input : (input && input.url ? input.url : "");
    const target = isTarget(url);
    if (target) lmLog("fetch:target url=" + url);
    const fetchT0 = perfNow();

    try {
      const resp = await _fetch(input, init);
      try { handleSuccessfulAuthRequest(url, resp && typeof resp.status === "number" ? resp.status : 0); } catch (_) {}
      if (!target) return resp;
      if (!resp || resp.status < 200 || resp.status >= 300) return resp;
      lmLog("fetch:status=" + resp.status + " url=" + url);
      perfLog("fetch:network elapsed=" + (perfNow() - fetchT0).toFixed(1) + "ms url=" + url);

      let topJson = await resp.clone().json();
      const chicken = getChickenFast(url);
      lmLog("fetch:chickenCached=" + (!!chicken) + " url=" + url);
      if (topJson && Array.isArray(topJson.data)) {
        lmLog("fetch:payload-before len=" + topJson.data.length + " responseType=fetch");
      }
      if (!chicken) {
        lmLog("fetch:defer-no-cache url=" + url);
        perfLog("fetch:defer-no-cache elapsed=" + (perfNow() - fetchT0).toFixed(1) + "ms url=" + url);
        return resp;
      }
      const modified = injectChicken(topJson, chicken, url);
      lmLog("fetch:modified=" + (!!modified) + " url=" + url);
      if (!modified) return resp;
      if (modified && Array.isArray(modified.data)) {
        const pos = modified.data.map((x, i) => isChickenItem(x) ? i : null).filter(x => x !== null).join(",");
        lmLog("fetch:payload-after len=" + modified.data.length + " chickenPos=" + pos);
      }
      scheduleStateRepatch("fetch");

      const body = JSON.stringify(modified);
      const headers = new Headers(resp.headers);
      headers.set("content-type", "application/json; charset=utf-8");
      return new Response(body, {
        status: resp.status,
        statusText: resp.statusText,
        headers
      });
    } catch (_) {
      lmLog("fetch:error url=" + url);
      perfLog("fetch:error elapsed=" + (perfNow() - fetchT0).toFixed(1) + "ms url=" + url);
      return _fetch(input, init);
    }
  };

  const _open = XMLHttpRequest.prototype.open;
  const _send = XMLHttpRequest.prototype.send;

  XMLHttpRequest.prototype.open = function(method, url) {
    this.__perfOpenAt = perfNow();
    this.__isTarget = isTarget(url);
    this.__isOriginalTarget = isOriginalTarget(url);
    this.__isLikelyAuth = isLikelyAuthRequest(url);
    this.__targetUrl = url;
    try {
      const u = new URL(url, location.href);
      if ((u.pathname || "").toLowerCase().includes("gamelist") &&
          (u.pathname || "").toLowerCase().includes("/frontapi/")) {
        observedGameListBase = u.origin + u.pathname;
      }
    } catch (_) {}
    lmLog("xhr.open url=" + url + " target=" + this.__isTarget + " original=" + this.__isOriginalTarget + " auth=" + this.__isLikelyAuth);
    return _open.apply(this, arguments);
  };

  XMLHttpRequest.prototype.send = function(body) {
    if (!this.__isTarget && !this.__isOriginalTarget && !this.__isLikelyAuth) return _send.apply(this, arguments);

    const xhr = this;
    const origOnReady = xhr.onreadystatechange;

    xhr.onreadystatechange = function() {
      const callOriginal = () => origOnReady ? origOnReady.apply(this, arguments) : undefined;
      try {
        if (xhr.readyState === 4 && xhr.__perfOpenAt) {
          perfLog("xhr:ready elapsed=" + (perfNow() - xhr.__perfOpenAt).toFixed(1) + "ms status=" + xhr.status + " responseType=" + String(xhr.responseType || "") + " url=" + (xhr.__targetUrl || ""));
        }
        if (xhr.readyState === 4 && xhr.__isLikelyAuth) {
          handleSuccessfulAuthRequest(xhr.__targetUrl, xhr.status || 0);
        }
        if (xhr.__isOriginalTarget && xhr.readyState === 4 && xhr.status >= 200 && xhr.status < 300) {
          try {
            const originalJson = JSON.parse(xhr.responseText);
            const chicken = extractChicken(originalJson);
            lmLog("xhr.original found=" + (!!chicken) + " url=" + xhr.__targetUrl);
            if (chicken) {
              cachedChicken = chicken;
              cachedAt = now();
              patchPendingLobbyRoots();
              patchLiveLobbyState(chicken);
            }
          } catch (_) {}
        }

        if (xhr.readyState === 4 && xhr.status >= 200 && xhr.status < 300 && xhr.__isTarget) {
          let topJson = null;
          try {
            topJson = JSON.parse(xhr.responseText);
          } catch (_) { return callOriginal(); }
          if (topJson && Array.isArray(topJson.data)) {
            lmLog("xhr.target payload-before len=" + topJson.data.length + " responseType=" + String(xhr.responseType || ""));
          }
          const chicken = getChickenFast(xhr.__targetUrl);
          lmLog("xhr.target chickenCached=" + (!!chicken) + " url=" + xhr.__targetUrl);
          if (!chicken) {
            lmLog("xhr.target defer-no-cache url=" + xhr.__targetUrl);
            return callOriginal();
          }
          const modified = injectChicken(topJson, chicken, xhr.__targetUrl);
          lmLog("xhr.target modified=" + (!!modified) + " url=" + xhr.__targetUrl);
          if (!modified) return callOriginal();
          if (modified && Array.isArray(modified.data)) {
            const pos = modified.data.map((x, i) => isChickenItem(x) ? i : null).filter(x => x !== null).join(",");
            lmLog("xhr.target payload-after len=" + modified.data.length + " chickenPos=" + pos);
          }

          const newText = JSON.stringify(modified);
          try {
            Object.defineProperty(xhr, "responseText", { value: newText });
            if ((xhr.responseType || "") === "json") {
              Object.defineProperty(xhr, "response", { value: modified });
            } else {
              Object.defineProperty(xhr, "response", { value: newText });
            }
            lmLog("xhr.target patch-apply-ok responseType=" + String(xhr.responseType || "") + " textLen=" + newText.length);
            scheduleStateRepatch("xhr-target");
          } catch (e) {
            lmLog("xhr.target patch-apply-failed err=" + String((e && e.message) ? e.message : e));
          }
          return callOriginal();
        }
      } catch (_) {}

      return callOriginal();
    };

    return _send.apply(this, arguments);
  };
})();
"""
    }
}

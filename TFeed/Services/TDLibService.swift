import Foundation
import TDLibKit
import UIKit

extension TDLibClient: @retroactive @unchecked Sendable {}
extension TDLibClientManager: @retroactive @unchecked Sendable {}
extension Chat: @retroactive @unchecked Sendable {}
extension Message: @retroactive @unchecked Sendable {}

actor TDLibService {
    static let shared = TDLibService()

    private var manager: TDLibClientManager?
    private var client: TDLibClient?
    let updateRouter = UpdateRouter()

    private init() {}

    func initialize() {
        let manager = TDLibClientManager()
        self.manager = manager

        let router = updateRouter
        let client = manager.createClient(updateHandler: { data, client in
            do {
                let update = try client.decoder.decode(Update.self, from: data)
                router.send(update)
            } catch {
                // Decoding failures are expected for unsupported update types
            }
        })
        self.client = client
    }

    func getClient() -> TDLibClient? {
        client
    }

    // MARK: - TDLib Parameters

    func setParameters() async throws {
        guard let client else { return }

        let documentsURL = FileManager.default.urls(
            for: .documentDirectory,
            in: .userDomainMask
        ).first!

        let databasePath = documentsURL
            .appendingPathComponent("tdlib", isDirectory: true)
            .path
        let filesPath = documentsURL
            .appendingPathComponent("tdlib_files", isDirectory: true)
            .path

        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let langCode = Locale.current.language.languageCode?.identifier ?? "en"
        let deviceModel = await UIDevice.current.model
        let systemVersion = await UIDevice.current.systemVersion

        try await client.setTdlibParameters(
            apiHash: Constants.apiHash,
            apiId: Constants.apiId,
            applicationVersion: appVersion,
            databaseDirectory: databasePath,
            databaseEncryptionKey: Data(),
            deviceModel: deviceModel,
            filesDirectory: filesPath,
            systemLanguageCode: langCode,
            systemVersion: systemVersion,
            useChatInfoDatabase: true,
            useFileDatabase: true,
            useMessageDatabase: true,
            useSecretChats: false,
            useTestDc: false
        )
    }

    // MARK: - Authorization

    func sendPhoneNumber(_ phoneNumber: String) async throws {
        guard let client else { return }
        try await client.setAuthenticationPhoneNumber(
            phoneNumber: phoneNumber,
            settings: nil
        )
    }

    func sendCode(_ code: String) async throws {
        guard let client else { return }
        try await client.checkAuthenticationCode(code: code)
    }

    func sendPassword(_ password: String) async throws {
        guard let client else { return }
        try await client.checkAuthenticationPassword(password: password)
    }

    func logOut() async throws {
        guard let client else { return }
        try await client.logOut()
    }
}

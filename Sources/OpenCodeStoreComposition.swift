import Foundation

extension OpenCodeSessionStore {
    convenience init(
        client: OpenCodeClient, session: OpenCodeSession, directory: String,
        defaults: UserDefaults = .standard
    ) {
        self.init(
            service: client, serverID: client.profile.id, session: session, directory: directory,
            defaults: defaults,
            remoteFiles: OpenCodeRemoteFileStore(service: OpenCodeRemoteFileService(
                client: client, session: session, directory: directory)))
    }
}

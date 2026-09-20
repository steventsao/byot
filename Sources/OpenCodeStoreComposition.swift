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
                client: client, session: session, directory: directory)),
            durableQueue: BYOTDurableQueue(profile: client.profile,
                route: BYOTPushRoute(serverID: client.profile.id, sessionID: session.id, directory: directory, workspace: session.workspaceID), defaults: defaults))
    }
}

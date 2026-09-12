import NIOCore
import NIOSSH

// MARK: - Auth delegate

/// Offers a fixed, ordered list of authentication methods (e.g. private key
/// then password), skipping any the server doesn't advertise.
final class OrderedAuthDelegate: NIOSSHClientUserAuthenticationDelegate {
    private let host: String
    private let username: String
    private let offers: [NIOSSHUserAuthenticationOffer.Offer]
    private var index = 0

    init(host: String, username: String, offers: [NIOSSHUserAuthenticationOffer.Offer]) {
        self.host = host
        self.username = username
        self.offers = offers
    }

    func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        while index < offers.count {
            let offer = offers[index]
            index += 1
            if isAdvertised(offer, in: availableMethods) {
                nextChallengePromise.succeed(
                    NIOSSHUserAuthenticationOffer(username: username, serviceName: "", offer: offer)
                )
                return
            }
        }
        nextChallengePromise.fail(SSHTransportError.endpoint(host, "Authentication failed: no accepted key or password."))
    }

    private func isAdvertised(
        _ offer: NIOSSHUserAuthenticationOffer.Offer,
        in methods: NIOSSHAvailableUserAuthenticationMethods
    ) -> Bool {
        switch offer {
        case .privateKey: return methods.contains(.publicKey)
        case .password: return methods.contains(.password)
        default: return true
        }
    }
}

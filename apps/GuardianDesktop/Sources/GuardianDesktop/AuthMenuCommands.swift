import SwiftUI

struct AuthMenuCommands: Commands {
    @Bindable var authSession: GoogleAuthSession

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button(authSession.signInActionTitle) {
                authSession.signIn()
            }
            .disabled(!authSession.canSignIn)

            Button("Sign Out") {
                authSession.signOut()
            }
            .disabled(!authSession.canSignOut)
        }
    }
}

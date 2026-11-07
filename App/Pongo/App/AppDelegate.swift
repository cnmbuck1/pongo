import UIKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        SoundManager.shared.prepare()
        return true
    }

    func application(_ application: UIApplication,
                     configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let config = UISceneConfiguration(name: "Default", sessionRole: connectingSceneSession.role)
        config.delegateClass = SceneDelegate.self
        return config
    }

    func application(_ application: UIApplication,
                     supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        .portrait
    }
}

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession,
               options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: windowScene)
        let nav = UINavigationController(rootViewController: MenuViewController())
        nav.setNavigationBarHidden(true, animated: false)
        nav.overrideUserInterfaceStyle = .dark
        window.rootViewController = nav
        window.makeKeyAndVisible()
        // Screenshot automation (CI): jump straight into a match.
        let args = ProcessInfo.processInfo.arguments
        if args.contains("-PongoAutostart") || args.contains("-PongoDemo") {
            let game = GameViewController(mode: .match, settings: AppSettings.load(),
                                          demo: args.contains("-PongoDemo"))
            nav.pushViewController(game, animated: false)
        }
        self.window = window
    }

    func sceneWillResignActive(_ scene: UIScene) {
        NotificationCenter.default.post(name: .pongoShouldPause, object: nil)
    }
}

extension Notification.Name {
    static let pongoShouldPause = Notification.Name("pongoShouldPause")
}

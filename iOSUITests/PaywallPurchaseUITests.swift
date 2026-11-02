import StoreKitTest
import XCTest

// Abonelik ekranının uçtan uca testi (Simülatör): StoreKit test oturumu iOS/Purchases/Products.storekit'le açılır, uygulama
// tanıtım modunda (`--tanitim`, sunucuya bağlanmaz) abonelik ekranıyla (`--paywall`) açılır. Satın alma ve geri yükleme
// gerçek RevenueCat SDK'sından geçer: RevenueCat'in StoreKit test işlemlerini doğrulaması için panelde "StoreKit
// testing" sertifikası yüklü olmalı (Xcode › Products.storekit › Editor › Save Public Certificate). Sunucudaki hak
// beklenmez (tanıtım modu), hesap App Store abonesi gösterilir. Her adımın ekran görüntüsü teste eklenir.
//
//   xcodebuild test -project AINotepad.xcodeproj -scheme AINotepadiOS -destination 'platform=iOS Simulator,name=iPhone 17' \
//     -derivedDataPath .build/xcode-ios -only-testing:AINotepadiOSUITests -resultBundlePath .build/paywall-ui.xcresult

@MainActor
final class PaywallPurchaseUITests: XCTestCase {
    /// Ekranın ya da Apple penceresinin gelmesi için en çok bekleme (sn).
    private let timeout: TimeInterval = 30

    override func setUp() async throws {
        continueAfterFailure = false
    }

    /// Uygulamayı İngilizce, tanıtım modunda ve abonelik ekranı açık başlatır.
    private func launchPaywall() -> XCUIApplication {
        let app: XCUIApplication = XCUIApplication()
        app.launchArguments = ["--tanitim", "--paywall", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        return app
    }

    private func attachScreenshot(name: String) {
        let attachment: XCTAttachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Ekranda tamamlanma ya da hata metnini bekler; hata görünürse metniyle başarısız olur.
    private func waitForCompletion(app: XCUIApplication, step: String) {
        let done: XCUIElement = app.staticTexts["Your subscription is active"]
        let failure: XCUIElement = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "The purchase couldn't be completed")).firstMatch
        let deadline: Date = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if done.exists {
                return
            }
            if failure.exists {
                attachScreenshot(name: "\(step)-failed")
                XCTFail("\(step): \(failure.label)")
                return
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }
        attachScreenshot(name: "\(step)-timeout")
        XCTFail("\(step): \(timeout) sn içinde tamamlanmadı")
    }

    func testMonthlyPurchaseRestoreAndManage() throws {
        let session: SKTestSession = try SKTestSession(configurationFileNamed: "Products")
        session.resetToDefaultState()
        session.clearTransactions()
        session.disableDialogs = true

        // 1. Abonelik ekranı: iki paket, fiyatlar StoreKit dosyasından.
        var app: XCUIApplication = launchPaywall()
        let monthly: XCUIElement = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Monthly")).firstMatch
        XCTAssertTrue(monthly.waitForExistence(timeout: timeout), "Aylık paket görünmedi")
        XCTAssertTrue(monthly.label.contains("$5.99"), "Aylık fiyat: \(monthly.label)")
        attachScreenshot(name: "1-paywall")

        // 2. Aylık satın alma (StoreKit test işlemi).
        monthly.tap()
        app.buttons["Subscribe"].tap()
        waitForCompletion(app: app, step: "purchase")
        XCTAssertEqual(session.allTransactions().count, 1)
        attachScreenshot(name: "2-purchased")

        // 3. Hesap ekranında "Aboneliği yönet": Apple'ın abonelik penceresi.
        app.buttons["Done"].tap()
        app.tabBars.buttons["Settings"].tap()
        app.buttons["settings.account"].tap()
        let manage: XCUIElement = app.buttons["Manage subscription"]
        XCTAssertTrue(manage.waitForExistence(timeout: timeout), "Aboneliği yönet görünmedi")
        attachScreenshot(name: "3-account")
        manage.tap()
        RunLoop.current.run(until: Date().addingTimeInterval(4))
        attachScreenshot(name: "4-manage-subscriptions")
        app.terminate()

        // 4. Geri yükleme: yeni açılışta aynı Apple test hesabındaki abonelik bu hesaba geri yüklenir.
        app = launchPaywall()
        let restore: XCUIElement = app.buttons["Restore Purchases"]
        XCTAssertTrue(restore.waitForExistence(timeout: timeout), "Geri yükle görünmedi")
        restore.tap()
        waitForCompletion(app: app, step: "restore")
        attachScreenshot(name: "5-restored")
    }
}

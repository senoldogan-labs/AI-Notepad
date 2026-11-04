import BackgroundTasks
import Foundation
import os

/// Yarıda kalan toplantı işlemesini sürdüren sistem görevinin kimliği; Info.plist'teki `BGTaskSchedulerPermittedIdentifiers`
/// (project.yml) listesinde olmalı.
let processingResumeTaskIdentifier: String = "com.senoldogan.AINotepad.hosted.resume"

/// iPhone arka planda işlemeyi keserse (kayıt kilit ekranından bitirildi ve sürdürülen işleme istenemedi, arka plan süresi
/// bitti, sürdürülen işlemenin süresi doldu) toplantının notu uygulama açılmayı beklemeden yazılsın diye sistemden ağ
/// varken çalışacak bir işleme görevi (`BGProcessingTask`) istenir. Görev başlayınca yüklü hesabın kaydedicisi yarıda
/// kalan toplantıları kaldığı yerden işler (son geçiş parçaları, sonucu ve notun parçaları toplantı klasöründedir); süre
/// dolarsa işleme iptal edilir, toplantı `processing` kalır ve görev yeniden istenir. Uygulama açılınca ve öne dönünce de
/// aynı sürdürme çalışır (`PhoneRecorder.resumeUnfinished`).
@MainActor
final class ProcessingResumeScheduler {
    static let shared: ProcessingResumeScheduler = ProcessingResumeScheduler()

    private static let logger: Logger = Logger(subsystem: "com.senoldogan.AINotepad", category: "ProcessingResume")

    /// Yüklü hesabın kaydedicisi (hesap yüklenince bağlanır; hesap değişince yenisi).
    weak var recorder: PhoneRecorder?

    private init() {}

    /// Görev işleyicisini kaydeder: sistem bunu uygulamanın açılışı bitmeden ister (`App.init`).
    func register() {
        let registered: Bool = BGTaskScheduler.shared.register(forTaskWithIdentifier: processingResumeTaskIdentifier, using: .main) { (task: BGTask) -> Void in
            MainActor.assumeIsolated {
                ProcessingResumeScheduler.shared.run(task: task)
            }
        }
        if !registered {
            Self.logger.error("İşlemeyi sürdürme görevi kaydedilemedi, görev: \(processingResumeTaskIdentifier, privacy: .public)")
        }
    }

    /// Ağ varken çalışacak sürdürme görevi ister (varsa yenisiyle değişir). İstek reddedilirse (arka plan çalışması
    /// kapalı, simülatör) uyarı loglanır; işleme uygulama açılınca sürer.
    func schedule(reason: String) {
        let request: BGProcessingTaskRequest = BGProcessingTaskRequest(identifier: processingResumeTaskIdentifier)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = false
        do {
            try BGTaskScheduler.shared.submit(request)
            Self.logger.info("İşlemeyi sürdürme görevi istendi, neden: \(reason, privacy: .public)")
        } catch {
            Self.logger.warning("İşlemeyi sürdürme görevi istenemedi, neden: \(reason, privacy: .public), hata: \(String(describing: error), privacy: .private)")
        }
    }

    /// Sistem görevi başladı: yarıda kalan toplantılar işlenir ve biter beklenir. Süre dolarsa işleme iptal edilir ve
    /// görev yeniden istenir; iş kalırsa da yeniden istenir.
    private func run(task: BGTask) {
        guard let recorder else {
            Self.logger.info("İşlemeyi sürdürme görevi başladı, yüklü hesap yok")
            task.setTaskCompleted(success: true)
            return
        }
        Self.logger.info("İşlemeyi sürdürme görevi başladı")
        let work: Task<Bool, Never> = Task { @MainActor in
            await recorder.resumeUnfinishedAndWait()
        }
        task.expirationHandler = { @Sendable () -> Void in
            Task { @MainActor in
                Self.logger.warning("İşlemeyi sürdürme görevinin süresi doldu, işleme iptal ediliyor")
                recorder.cancelProcessingForSystem()
                work.cancel()
            }
        }
        Task { @MainActor in
            let finished: Bool = await work.value
            Self.logger.info("İşlemeyi sürdürme görevi bitti, iş kaldı: \(!finished, privacy: .public)")
            if !finished {
                self.schedule(reason: "iş kaldı")
            }
            task.setTaskCompleted(success: finished)
        }
    }
}

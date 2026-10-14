//
//  LifeMangaApp.swift
//  LifeManga
//
//  应用入口
//

import SwiftUI
import UIKit

final class LifeMangaAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        guard identifier == BackgroundTaskRunner.sessionIdentifier else {
            completionHandler()
            return
        }
        BackgroundTaskRunner.shared.backgroundCompletionHandler = completionHandler
    }
}

@main
struct LifeMangaApp: App {

    @UIApplicationDelegateAdaptor(LifeMangaAppDelegate.self) private var appDelegate
    @StateObject private var settings = AppSettings()

    init() {
        // 提前 init 后台 URLSession（让它登记到系统）
        _ = BackgroundTaskRunner.shared
        // 尝试消费上一次进程结束后遗留的后台任务结果
        Task { @MainActor in
            BackgroundTaskRunner.shared.recoverPersistedResponses()
            OpenAIService.shared.resumeServerBackedJobs()
        }
        // 申请本地通知权限（首次会弹一次系统弹窗）
        LocalNotifier.requestAuthorizationIfNeeded()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(settings)
                .tint(.indigo)
        }
    }
}

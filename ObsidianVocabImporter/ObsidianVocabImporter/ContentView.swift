import SwiftUI

struct ContentView: View {
    @StateObject private var importerVM = ImporterViewModel()
    @StateObject private var captureVM = QuickCaptureViewModel()
    @StateObject private var subtitleVM = SubtitleImportViewModel()
    @StateObject private var reviewVM = ReviewModeViewModel()

    var body: some View {
        TabView {
            ImportTabView(vm: importerVM)
                .tabItem { Text("导入") }

            QuickCaptureView(
                vm: captureVM,
                onClose: {
                    captureVM.text = ""
                    captureVM.translation = ""
                    captureVM.source = ""
                    captureVM.statusText = ""
                }
            )
            .tabItem { Text("快速捕获") }
            .onAppear {
                captureVM.vaultURLOverride = importerVM.vaultURL
            }

            SubtitleImportView(vm: subtitleVM)
                .tabItem { Text("字幕") }
                .onAppear {
                    subtitleVM.vaultURLOverride = importerVM.vaultURL
                }

            ReviewModeView(vm: reviewVM)
                .tabItem { Text("复习") }
                .onAppear {
                    reviewVM.vaultURLOverride = importerVM.vaultURL
                }
        }
    }
}


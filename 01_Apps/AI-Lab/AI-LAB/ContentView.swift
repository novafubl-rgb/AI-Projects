import SwiftUI
import PhotosUI
import LocalAuthentication
import UIKit

struct StoredPhoto: Identifiable, Codable, Equatable {
    let id: UUID
    let filename: String
    let createdAt: Date
}

enum AppScreen {
    case setupPasscode
    case unlock
    case vault
}

enum PasscodeChangeState {
    case verifyOld
    case enterNew
    case confirmNew
}

final class KeychainService {
    private let account = "app-passcode"
    private let service = "com.ai-lab.passcode"

    func savePasscode(_ passcode: String) -> Bool {
        guard let data = passcode.data(using: .utf8) else { return false }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)

        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data
        ]
        return SecItemAdd(addQuery as CFDictionary, nil) == errSecSuccess
    }

    func loadPasscode() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard
            status == errSecSuccess,
            let data = result as? Data,
            let value = String(data: data, encoding: .utf8)
        else {
            return nil
        }
        return value
    }
}

enum BiometricAuthService {
    static func authenticate() async -> Bool {
        let context = LAContext()
        var error: NSError?

        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            return false
        }

        do {
            return try await context.evaluatePolicy(
                .deviceOwnerAuthenticationWithBiometrics,
                localizedReason: "使用 Face ID 解锁 AI-LAB"
            )
        } catch {
            return false
        }
    }
}

final class PhotoVaultStore {
    private let folderName = "PrivatePhotos"
    private let indexName = "photo-index.json"

    private func directoryURL() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dir = base.appendingPathComponent(folderName, isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    private func indexURL() throws -> URL {
        try directoryURL().appendingPathComponent(indexName)
    }

    func loadPhotos() throws -> [StoredPhoto] {
        let url = try indexURL()
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode([StoredPhoto].self, from: data)
    }

    func savePhotos(_ photos: [StoredPhoto]) throws {
        let data = try JSONEncoder().encode(photos)
        try data.write(to: indexURL(), options: .atomic)
    }

    func importPhoto(data: Data) throws -> StoredPhoto {
        let id = UUID()
        let filename = "\(id.uuidString).jpg"
        let fileURL = try directoryURL().appendingPathComponent(filename)
        try data.write(to: fileURL, options: .atomic)
        return StoredPhoto(id: id, filename: filename, createdAt: Date())
    }

    func removePhoto(_ photo: StoredPhoto) throws {
        let fileURL = try directoryURL().appendingPathComponent(photo.filename)
        if FileManager.default.fileExists(atPath: fileURL.path) {
            try FileManager.default.removeItem(at: fileURL)
        }
    }

    func imageData(for photo: StoredPhoto) throws -> Data {
        let fileURL = try directoryURL().appendingPathComponent(photo.filename)
        return try Data(contentsOf: fileURL)
    }
}

@MainActor
final class AppViewModel: ObservableObject {
    @Published var screen: AppScreen = .unlock
    @Published var setupEntry = ""
    @Published var setupConfirm = ""
    @Published var unlockEntry = ""
    @Published var changeEntry = ""
    @Published var newPassEntry = ""
    @Published var confirmPassEntry = ""
    @Published var changeState: PasscodeChangeState = .verifyOld
    @Published var showChangeSheet = false
    @Published var message = ""
    @Published var photos: [StoredPhoto] = []
    @Published var selectedPhoto: StoredPhoto?

    private let keychain = KeychainService()
    private let store = PhotoVaultStore()

    init() {
        if keychain.loadPasscode() == nil {
            screen = .setupPasscode
        } else {
            screen = .unlock
        }
        Task { await refreshPhotos() }
    }

    func setupPasscode() {
        guard setupEntry.count == 4, setupEntry.allSatisfy(\.isNumber) else {
            message = "请输入 4 位数字密码"
            return
        }
        guard setupEntry == setupConfirm else {
            message = "两次输入不一致"
            return
        }
        guard keychain.savePasscode(setupEntry) else {
            message = "保存密码失败"
            return
        }
        setupEntry = ""
        setupConfirm = ""
        message = ""
        screen = .vault
    }

    func unlock() {
        guard let stored = keychain.loadPasscode() else {
            screen = .setupPasscode
            return
        }
        if unlockEntry == stored {
            unlockEntry = ""
            message = ""
            screen = .vault
        } else {
            message = "密码错误"
        }
    }

    func unlockWithFaceID() {
        Task {
            let ok = await BiometricAuthService.authenticate()
            if ok {
                unlockEntry = ""
                message = ""
                screen = .vault
            } else {
                message = "Face ID 验证失败"
            }
        }
    }

    func lock() {
        screen = .unlock
    }

    func openChangePasscode() {
        changeState = .verifyOld
        changeEntry = ""
        newPassEntry = ""
        confirmPassEntry = ""
        message = ""
        showChangeSheet = true
    }

    func submitPasscodeChange() {
        guard let stored = keychain.loadPasscode() else {
            screen = .setupPasscode
            showChangeSheet = false
            return
        }

        switch changeState {
        case .verifyOld:
            if changeEntry == stored {
                changeState = .enterNew
                message = ""
            } else {
                message = "旧密码错误"
            }
        case .enterNew:
            guard newPassEntry.count == 4, newPassEntry.allSatisfy(\.isNumber) else {
                message = "新密码必须是 4 位数字"
                return
            }
            changeState = .confirmNew
            message = ""
        case .confirmNew:
            guard newPassEntry == confirmPassEntry else {
                message = "两次新密码不一致"
                return
            }
            guard keychain.savePasscode(newPassEntry) else {
                message = "修改密码失败"
                return
            }
            showChangeSheet = false
            message = ""
        }
    }

    func refreshPhotos() async {
        do {
            photos = try store.loadPhotos().sorted { $0.createdAt > $1.createdAt }
        } catch {
            message = "读取照片失败"
        }
    }

    func importPhotos(items: [PhotosPickerItem]) {
        Task {
            var current = photos
            for item in items {
                if let data = try? await item.loadTransferable(type: Data.self),
                   let image = UIImage(data: data),
                   let jpeg = image.jpegData(compressionQuality: 0.95),
                   let photo = try? store.importPhoto(data: jpeg) {
                    current.insert(photo, at: 0)
                }
            }
            do {
                try store.savePhotos(current)
                photos = current
            } catch {
                message = "保存照片失败"
            }
        }
    }

    func deletePhoto(_ photo: StoredPhoto) {
        Task {
            do {
                try store.removePhoto(photo)
                photos.removeAll { $0.id == photo.id }
                try store.savePhotos(photos)
                if selectedPhoto?.id == photo.id {
                    selectedPhoto = nil
                }
            } catch {
                message = "删除失败"
            }
        }
    }

    func image(for photo: StoredPhoto) -> UIImage? {
        (try? store.imageData(for: photo)).flatMap(UIImage.init(data:))
    }
}

struct ContentView: View {
    @StateObject private var vm = AppViewModel()

    var body: some View {
        ZStack {
            Color(.systemBackground).ignoresSafeArea()
            switch vm.screen {
            case .setupPasscode:
                SetPasscodeView(vm: vm)
            case .unlock:
                UnlockView(vm: vm)
            case .vault:
                VaultView(vm: vm)
            }
        }
        .sheet(isPresented: $vm.showChangeSheet) {
            ChangePasscodeView(vm: vm)
        }
        .fullScreenCover(item: $vm.selectedPhoto) { photo in
            PhotoViewerView(vm: vm, startPhoto: photo)
        }
    }
}

struct SetPasscodeView: View {
    @ObservedObject var vm: AppViewModel

    var body: some View {
        VStack(spacing: 18) {
            Text("AI-LAB")
                .font(.largeTitle).bold()
            Text("首次启动，请设置 4 位数字密码")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            SecureField("输入 4 位密码", text: $vm.setupEntry)
                .textFieldStyle(.roundedBorder)
                .keyboardType(.numberPad)

            SecureField("再次输入密码", text: $vm.setupConfirm)
                .textFieldStyle(.roundedBorder)
                .keyboardType(.numberPad)

            Button("保存密码") { vm.setupPasscode() }
                .buttonStyle(.borderedProminent)

            if !vm.message.isEmpty {
                Text(vm.message).foregroundStyle(.red)
            }
        }
        .padding(.horizontal, 24)
        .safeAreaInset(edge: .top) { Color.clear.frame(height: 8) }
    }
}

struct UnlockView: View {
    @ObservedObject var vm: AppViewModel

    var body: some View {
        VStack(spacing: 18) {
            Text("AI-LAB")
                .font(.largeTitle).bold()
            Text("输入密码解锁")
                .foregroundStyle(.secondary)

            SecureField("4 位数字密码", text: $vm.unlockEntry)
                .textFieldStyle(.roundedBorder)
                .keyboardType(.numberPad)

            Button("解锁") { vm.unlock() }
                .buttonStyle(.borderedProminent)

            Button("使用 Face ID") { vm.unlockWithFaceID() }
                .buttonStyle(.bordered)

            if !vm.message.isEmpty {
                Text(vm.message).foregroundStyle(.red)
            }
        }
        .padding(.horizontal, 24)
        .safeAreaInset(edge: .top) { Color.clear.frame(height: 8) }
    }
}

struct VaultView: View {
    @ObservedObject var vm: AppViewModel
    @State private var pickerItems: [PhotosPickerItem] = []

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 3)

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(vm.photos) { photo in
                        Group {
                            if let image = vm.image(for: photo) {
                                Image(uiImage: image)
                                    .resizable()
                                    .scaledToFill()
                            } else {
                                Color.secondary.opacity(0.2)
                            }
                        }
                        .frame(height: 120)
                        .frame(maxWidth: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .contentShape(Rectangle())
                        .onTapGesture {
                            vm.selectedPhoto = photo
                        }
                        .contextMenu {
                            Button(role: .destructive) {
                                vm.deletePhoto(photo)
                            } label: {
                                Label("删除", systemImage: "trash")
                            }
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.top, 12)
            }
            .navigationTitle("AI-LAB")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("锁定") { vm.lock() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("修改密码") { vm.openChangePasscode() }
                    } label: {
                        Image(systemName: "gearshape")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    PhotosPicker(
                        selection: $pickerItems,
                        maxSelectionCount: 0,
                        matching: .images
                    ) {
                        Image(systemName: "plus")
                    }
                }
            }
            .onChange(of: pickerItems) { newItems in
                vm.importPhotos(items: newItems)
            }
            .safeAreaInset(edge: .bottom) { Color.clear.frame(height: 8) }
        }
    }
}

struct PhotoViewerView: View {
    @ObservedObject var vm: AppViewModel
    let startPhoto: StoredPhoto
    @State private var selection: UUID
    @Environment(\.dismiss) private var dismiss

    init(vm: AppViewModel, startPhoto: StoredPhoto) {
        self.vm = vm
        self.startPhoto = startPhoto
        _selection = State(initialValue: startPhoto.id)
    }

    var body: some View {
        NavigationStack {
            TabView(selection: $selection) {
                ForEach(vm.photos) { photo in
                    ZStack {
                        Color.black.ignoresSafeArea()
                        if let image = vm.image(for: photo) {
                            Image(uiImage: image)
                                .resizable()
                                .scaledToFit()
                                .padding(.horizontal, 6)
                        } else {
                            ProgressView()
                                .tint(.white)
                        }
                    }
                    .tag(photo.id)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("关闭") { dismiss() }
                        .foregroundStyle(.white)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(role: .destructive) {
                        if let current = vm.photos.first(where: { $0.id == selection }) {
                            vm.deletePhoto(current)
                            if vm.photos.isEmpty {
                                dismiss()
                            } else if let first = vm.photos.first {
                                selection = first.id
                            }
                        }
                    } label: {
                        Image(systemName: "trash")
                    }
                    .foregroundStyle(.red)
                }
            }
            .toolbarBackground(.hidden, for: .navigationBar)
        }
        .preferredColorScheme(.dark)
    }
}

struct ChangePasscodeView: View {
    @ObservedObject var vm: AppViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                switch vm.changeState {
                case .verifyOld:
                    SecureField("输入旧密码", text: $vm.changeEntry)
                        .textFieldStyle(.roundedBorder)
                        .keyboardType(.numberPad)
                case .enterNew:
                    SecureField("输入新密码", text: $vm.newPassEntry)
                        .textFieldStyle(.roundedBorder)
                        .keyboardType(.numberPad)
                case .confirmNew:
                    SecureField("确认新密码", text: $vm.confirmPassEntry)
                        .textFieldStyle(.roundedBorder)
                        .keyboardType(.numberPad)
                }

                Button("下一步") { vm.submitPasscodeChange() }
                    .buttonStyle(.borderedProminent)

                if !vm.message.isEmpty {
                    Text(vm.message).foregroundStyle(.red)
                }
                Spacer()
            }
            .padding(20)
            .navigationTitle("修改密码")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("关闭") {
                        vm.showChangeSheet = false
                        dismiss()
                    }
                }
            }
        }
    }
}

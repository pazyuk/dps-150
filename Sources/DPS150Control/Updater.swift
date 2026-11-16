// SPDX-License-Identifier: GPL-3.0-or-later
// Updates from GitHub Releases: a check on launch and on demand, a sheet with
// the release notes, download and install.
// Enabled only if Info.plist has DPSUpdateRepo ("owner/repository") —
// build_app.sh writes it into the regular build; the App Store build and
// `swift run` have no such key (the App Store does the updating there).
// Installing works only when the app is signed with a certificate that has a Team ID:
// the downloaded build must satisfy the designated requirement of the current one (the same
// identifier and the same team). Ad-hoc builds have nothing to check against — for those
// we open the release page.
import AppKit
import DPS150Kit
import Security
import SwiftUI

struct Release: Decodable {
    struct Asset: Decodable {
        let name: String
        let browser_download_url: String
    }
    let tag_name: String
    let body: String?
    let html_url: String
    let assets: [Asset]

    var version: String { tag_name.hasPrefix("v") ? String(tag_name.dropFirst()) : tag_name }
}

@Observable final class Updater {
    static let shared = Updater()

    let repo = Bundle.main.object(forInfoDictionaryKey: "DPSUpdateRepo") as? String
    let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    var available: Release?
    var installing = false

    var enabled: Bool { repo != nil }

    /// manual: also report "no updates" and network errors.
    func check(manual: Bool) {
        // DPS150_UPDATE_URL — overrides the address to test updating without GitHub (file:// will do).
        guard let repo, let url = URL(string: ProcessInfo.processInfo.environment["DPS150_UPDATE_URL"]
                                      ?? "https://api.github.com/repos/\(repo)/releases/latest") else { return }
        URLSession.shared.dataTask(with: url) { data, _, err in
            let rel = data.flatMap { try? JSONDecoder().decode(Release.self, from: $0) }
            DispatchQueue.main.async { [self] in
                guard let rel else {
                    if manual {
                        alert(L("Не удалось проверить обновления: %@",
                                err?.localizedDescription ?? L("неожиданный ответ сервера")))
                    }
                    return
                }
                if rel.version.compare(current, options: .numeric) == .orderedDescending {
                    available = rel
                } else if manual {
                    alert(L("У вас последняя версия (%@).", current))
                }
            }
        }.resume()
    }

    // ---- installing ----------------------------------------------------------

    private static let selfCode: SecStaticCode? = {
        var code: SecCode?
        var st: SecStaticCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &st) == errSecSuccess else { return nil }
        return st
    }()

    /// Whether our signature has a Team ID (i.e. the build is not ad-hoc).
    let canInstall: Bool = {
        var info: CFDictionary?
        guard let code = selfCode,
              SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess
        else { return false }
        return (info as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] != nil
    }()

    /// The downloaded app must be signed the same way as the current one.
    private func verify(_ app: URL) throws {
        var req: SecRequirement?
        var new: SecStaticCode?
        guard let code = Self.selfCode,
              SecCodeCopyDesignatedRequirement(code, [], &req) == errSecSuccess, let req,
              SecStaticCodeCreateWithPath(app as CFURL, [], &new) == errSecSuccess, let new else {
            throw UpdateError(errorDescription: L("Не удалось проверить подпись обновления"))
        }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate)
        guard SecStaticCodeCheckValidity(new, flags, req) == errSecSuccess else {
            throw UpdateError(errorDescription: L("Подпись обновления не совпадает с подписью этого приложения"))
        }
    }

    func install(_ rel: Release) {
        if AppModel.shared.charging {
            return alert(L("Идёт заряд. Обновите приложение после его окончания."))
        }
        guard canInstall, let asset = rel.assets.first(where: { $0.name.hasSuffix(".zip") }),
              let url = URL(string: asset.browser_download_url) else {
            if let page = URL(string: rel.html_url) { NSWorkspace.shared.open(page) }
            available = nil
            return
        }
        installing = true
        URLSession.shared.downloadTask(with: url) { [self] tmp, _, err in
            var failure: String?
            do {
                guard let tmp else { throw err ?? URLError(.badServerResponse) }
                let fm = FileManager.default
                let dst = Bundle.main.bundleURL
                // a temporary folder on the same volume as the app — so that the replacement is atomic
                let dir = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                     appropriateFor: dst, create: true)
                defer { try? fm.removeItem(at: dir) }
                let unzip = Process()
                unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
                unzip.arguments = ["-x", "-k", tmp.path, dir.path]
                try unzip.run()
                unzip.waitUntilExit()
                guard unzip.terminationStatus == 0,
                      let app = try fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
                          .first(where: { $0.pathExtension == "app" }) else {
                    throw UpdateError(errorDescription: L("В архиве обновления нет приложения"))
                }
                try verify(app)
                _ = try fm.replaceItemAt(dst, withItemAt: app)
            } catch {
                failure = error.localizedDescription
            }
            DispatchQueue.main.async { [self] in
                installing = false
                if let failure {
                    alert(L("Не удалось установить обновление: %@", failure))
                    if let page = URL(string: rel.html_url) { NSWorkspace.shared.open(page) }
                    return
                }
                // Relaunch: the new instance starts once this one exits.
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/bin/sh")
                p.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", Bundle.main.bundlePath]
                try? p.run()
                // Not NSApp.terminate: it does nothing while the update sheet is open.
                AppModel.shared.stopRecording()
                AppModel.shared.disconnect()
                exit(0)
            }
        }.resume()
    }
}

struct UpdateError: LocalizedError {
    var errorDescription: String?
}

struct UpdateSheet: View {
    @Bindable var u: Updater
    let rel: Release

    // ponytail: GitHub Markdown is shown as text with inline markup (bold, links);
    // headings and lists stay as "##" and "-". Full rendering — if it becomes a nuisance.
    private var notes: AttributedString {
        let body = rel.body?.isEmpty == false ? rel.body! : L("Описание релиза не заполнено.")
        return (try? AttributedString(markdown: body, options: .init(
            interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(body)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("Доступна новая версия %@", rel.version)).font(.title2.bold())
            Text(L("У вас установлена версия %@.", u.current)).foregroundStyle(cDim)
            ScrollView {
                Text(notes).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(10)
            }
            .background(cPanel, in: RoundedRectangle(cornerRadius: 8))
            HStack {
                if u.installing { ProgressView().controlSize(.small); Text("Загрузка и установка…") }
                Spacer()
                Button("Позже") { u.available = nil }.keyboardShortcut(.cancelAction)
                if u.canInstall {
                    Button("Страница релиза") { URL(string: rel.html_url).map { _ = NSWorkspace.shared.open($0) } }
                    Button("Обновить и перезапустить") { u.install(rel) }.keyboardShortcut(.defaultAction)
                } else {
                    Button("Открыть страницу релиза") { u.install(rel) }.keyboardShortcut(.defaultAction)
                }
            }
            .disabled(u.installing)
        }
        .padding(16)
        .frame(width: 560, height: 420)
    }
}

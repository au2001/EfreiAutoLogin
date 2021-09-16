//
//  ContentView.swift
//  EfreiAutoLogin
//
//  Created by Aurélien Garnier on 15/09/2021.
//

import Cocoa
import SwiftUI
import Combine

struct ContentView: View {
    @State var username: String = ""
    @State var password: String = ""
    
    func load() -> (String, String)? {
        guard let username = UserDefaults.standard.string(forKey: "username") else {
            return nil
        }
        
        let bundleId = Bundle.main.infoDictionary?[kCFBundleIdentifierKey as String] as! CFString

        var itemCopy: AnyObject?
        let status = SecItemCopyMatching([
            kSecAttrService: bundleId,
            kSecAttrAccount: username,
            kSecClass: kSecClassGenericPassword,
            kSecMatchLimit: kSecMatchLimitOne,
            kSecReturnData: kCFBooleanTrue!
        ] as CFDictionary, &itemCopy)

        guard status == errSecSuccess else {
            print("Failed to load password: \(SecCopyErrorMessageString(status, nil) ?? "nil" as CFString)")
            return (username, "")
        }

        guard let passwordData = itemCopy as? Data else {
            return (username, "")
        }

        guard let password = String(data: passwordData, encoding: .utf8) else {
            return (username, "")
        }

        return (username, password)
    }
    
    func save() {
        UserDefaults.standard.setValue(self.username, forKey: "username")

        let bundleId = Bundle.main.infoDictionary?[kCFBundleIdentifierKey as String] as! CFString

        var status = SecItemAdd([
            kSecAttrService: bundleId,
            kSecAttrAccount: self.username,
            kSecClass: kSecClassGenericPassword,
            kSecValueData: self.password
        ] as CFDictionary, nil)

        if status == errSecDuplicateItem {
            status = SecItemUpdate([
                kSecAttrService: bundleId,
                kSecAttrAccount: self.username,
                kSecClass: kSecClassGenericPassword,
                kSecMatchLimit: kSecMatchLimitOne
            ] as CFDictionary, [
                kSecValueData: self.password.data(using: .utf8)
            ] as CFDictionary)
        }
        
        guard status == errSecSuccess else {
            print("Failed to save password: \(SecCopyErrorMessageString(status, nil) ?? "nil" as CFString)")
            return
        }
    }

    var body: some View {
        VStack {
            let usernameBinding = Binding<String>(get: { self.username }, set: { value in
                self.username = value
                self.save()
            })
            let passwordBinding = Binding<String>(get: { self.password }, set: { value in
                self.password = value
                self.save()
            })

            Text("Username:")
                .padding([.horizontal, .top], 10)

            TextField("Username", text: usernameBinding)
                .textFieldStyle(RoundedBorderTextFieldStyle())
                .padding(.horizontal, 10)

            Text("Password:")
                .padding([.horizontal, .top], 10)

            SecureField("Password", text: passwordBinding)
                .textFieldStyle(RoundedBorderTextFieldStyle())
                .padding(.horizontal, 10)

            HStack {
                Button("Login", action: {
                    let app = NSApplication.shared.delegate as! AppDelegate
                    app.checkPortal()
                })
                    .buttonStyle(BorderedButtonStyle())
                    .padding(10)

                Button("Logout", action: {
                    let app = NSApplication.shared.delegate as! AppDelegate
                    app.logout()
                })
                    .buttonStyle(BorderedButtonStyle())
                    .padding(10)

                Button("Quit", action: {
                    exit(0)
                })
                    .padding(10)
            }
        }.onAppear(perform: {
            guard let (username, password) = self.load() else {
                return
            }

            self.username = username
            self.password = password
        })
    }
}


struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}

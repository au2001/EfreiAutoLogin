//
//  AppDelegate.swift
//  EfreiAutoLogin
//
//  Created by Aurélien Garnier on 15/09/2021.
//

import Cocoa
import SwiftUI
import SystemConfiguration
import NetworkExtension

@main
class AppDelegate: NSObject, NSApplicationDelegate {

    var popover: NSPopover!
    var statusBarItem: NSStatusItem!
    var contentView: ContentView?
    
    var efreiSSID: [String]?
    var testURL: URL?
    var testResult: String?
    var portalHost: String?
    var defaultLogoutURL: URL?
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        self.contentView = ContentView()
        self.loadConfig()

        // Create the popover
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: self.contentView)
        self.popover = popover
        
        // Create the status item
        self.statusBarItem = NSStatusBar.system.statusItem(withLength: CGFloat(NSStatusItem.variableLength))
        if let button = self.statusBarItem.button {
            button.image = NSImage(named: "MenuIcon")
            button.action = #selector(togglePopover(_:))
        }
        
        // Register daemon
        self.listenNetwork()
    }
    
    @objc func togglePopover(_ sender: AnyObject?) {
        if let button = self.statusBarItem.button {
            if self.popover.isShown {
                self.popover.performClose(sender)
            } else {
                self.popover.show(relativeTo: button.bounds, of: button, preferredEdge: NSRectEdge.minY)
                self.popover.contentViewController?.view.window?.becomeKey()
            }
        }
    }
    
    func loadConfig() {
        guard let path = Bundle.main.path(forResource: "Config", ofType: "plist") else {
            return
        }
        
        let config = NSDictionary(contentsOfFile: path)
        self.efreiSSID = config?["Efrei SSID"] as? [String]
        self.portalHost = config?["Captive Portal Host"] as? String
        self.defaultLogoutURL = URL(string: config?["Captive Portal Logout URL"] as? String ?? "")
        self.testURL = URL(string: config?["Connection Test URL"] as? String ?? "")
        self.testResult = config?["Connection Test Success Result"] as? String
    }
    
    func listenNetwork() {
        let callback: SCDynamicStoreCallBack = { (store, _, context) in
            guard let context = context else {
                return
            }

            let app = Unmanaged<AppDelegate>.fromOpaque(context).takeUnretainedValue()
            app.networkUpdated(store)
        }
        var context = SCDynamicStoreContext()
        context.info = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())

        let bundleName = Bundle.main.infoDictionary?[kCFBundleNameKey as String] as! CFString
        if let store = SCDynamicStoreCreate(nil, bundleName, callback, &context) {
            self.checkAssistant(store)
            self.networkUpdated(store)

            SCDynamicStoreSetNotificationKeys(store, [
                "State:/Network/Global/IPv4"
            ] as CFArray, [
//                "Setup:/Network/Service/.*/Interface",
//                "State:/Network/Interface/.*/AirPort",
//                "State:/Network/Interface/.*/CaptiveNetwork"
            ] as CFArray)
            SCDynamicStoreSetDispatchQueue(store, DispatchQueue.main)
        }
    }
    
    func networkUpdated(_ store: SCDynamicStore) {
        // Ensure connected to WiFi (Ethernet doesn't have a captive portal)
        guard let ipv4State = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [CFString: Any]
            else { return } // Not connected to a network
        guard let primaryServiceID = ipv4State[kSCDynamicStorePropNetPrimaryService] else {
            print("Failed to fetch primary network service")
            return
        }
        let interfaceSetupName = "Setup:/Network/Service/\(primaryServiceID)/Interface" as CFString
        guard let interfaceSetup = SCDynamicStoreCopyValue(store, interfaceSetupName) as? [CFString: Any] else {
            print("Failed to fetch interface state for service \(primaryServiceID)")
            return
        }
        guard interfaceSetup[kSCPropNetInterfaceHardware] as! CFString == kSCEntNetAirPort else {
            print("Failed to fetch interface hardware type")
            return
        }
        
        // Ensure (B)SSID corresponds to one of Efrei's
        let interfaceName = interfaceSetup[kSCPropNetInterfaceDeviceName] as! CFString
        let airportStateName = "State:/Network/Interface/\(interfaceName)/AirPort" as CFString
        guard let airportState = SCDynamicStoreCopyValue(store, airportStateName) as? [CFString: Any] else {
            print("Failed to fetch network state for interface \(interfaceName)")
            return
        }
//        guard let bssidData = airportState["BSSID" as CFString] as? Data else {
//            print("Failed to fetch network BSSID")
//            return
//        }
//        let bssid = bssidData.reduce([], { (arr, byte) in arr + [String(format: "%02x", byte)] }).joined(separator: ":")
        let ssid = airportState["SSID_STR" as CFString] as! String
        guard efreiSSID?.contains(ssid) ?? false
            else { return } // This is another network as Efrei
        
        self.checkPortal()
    }
    
    func checkPortal(withMaxRetries retries: Int = 3) {
        let task = URLSession(configuration: .ephemeral).dataTask(with: self.testURL!, completionHandler: { (data, response, error) in
            guard let data = data, let response = response else {
                print("Request failed (offline?): \(error?.localizedDescription ?? "nil")")
                return
            }

            if String(data: data, encoding: .utf8) == self.testResult
                { return } // Successfully connected and has access to internet

            guard response.url?.host == self.portalHost else {
                print("Unrecognized portal: \(response.url?.absoluteString ?? "nil")")
                return
            }
            
            if retries > 0 {
                self.login(at: response.url!, withMaxRetries: retries - 1)
            } else {
                print("Failed to login (wrong password?): \n\(String(data: data, encoding: .utf8) ?? "nil")")
            }
        })
        task.resume()
    }
    
    func login(at url: URL, withMaxRetries retries: Int = 0) {
        let (username, password) = self.contentView?.load() ?? ("", "")

        var query = URLComponents()
        query.queryItems = [
            URLQueryItem(name: "user", value: username),
            URLQueryItem(name: "password", value: password)
        ]
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.allHTTPHeaderFields = [
            "Content-Type": "application/x-www-form-urlencoded"
        ]
        request.httpBody = query.query?.data(using: .utf8)
        let task = URLSession(configuration: .ephemeral).dataTask(with: request, completionHandler: { (data, response, error) in
            print("Logged in.")
            self.checkPortal(withMaxRetries: retries)
        })
        task.resume()
    }
    
    func logout(at url: URL? = nil) {
        let task = URLSession(configuration: .ephemeral).dataTask(with: url ?? self.defaultLogoutURL!)
        task.resume()
    }
    
    func checkAssistant(_ store: SCDynamicStore) {
        guard let captiveState = SCDynamicStoreCopyMultiple(store, [] as CFArray, ["State:/Network/Interface/.*/CaptiveNetwork"] as CFArray) as? Dictionary<String, Any>
            else { return }
        if captiveState.isEmpty { return }
        
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Warning: Captive Network Assistant must be disabled."
        alert.informativeText = "The native Captive Portal pop-up conflicts with this app. To disable it, type the following command in your Terminal and then RESTART your computer:\n\nsudo defaults write /Library/Preferences/SystemConfiguration/com.apple.captive.control Active -boolean false"
        alert.addButton(withTitle: "Dismiss")
        alert.runModal()
    }

}

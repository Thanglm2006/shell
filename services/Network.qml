pragma Singleton

import Quickshell
import Quickshell.Io
import QtQuick

Singleton {
    id: root

    // --- IMPORTANT: Network interface name set correctly ---
    readonly property string interfaceName: "wlo1"
    // -------------------------------------------------------

    readonly property list<AccessPoint> networks: []
    readonly property AccessPoint active: networks.find(n => n.active) ?? null
    property bool wifiEnabled: true
    readonly property bool scanning: rescanProc.running

    /**
     * Notification Service Helper
     * Calls 'notify-send' to display system-level alerts.
     */
    function sendNotification(summary, body, icon = "network-wireless"): void {
        notificationProc.exec(["notify-send", "-a", "WiFi Manager", "-i", icon, summary, body]);
    }

    function enableWifi(enabled: bool): void {
        const cmd = enabled ? "on" : "off";
        enableWifiProc.exec(["nmcli", "radio", "wifi", cmd]);
        
        // Notify of state change
        sendNotification("WiFi " + (enabled ? "Enabled" : "Disabled"), 
                         "Wireless radio has been turned " + cmd);
    }

    function toggleWifi(): void {
        enableWifi(!wifiEnabled);
    }

    function rescanWifi(): void {
        if (!rescanProc.running) rescanProc.running = true;
    }

    function connectToNetwork(ssid: string, password: string): void {
        // Stop any previous connection process
        connectProc.running = false;

        console.log("[Wifi] Connecting to: " + ssid + " on " + root.interfaceName);
        sendNotification("Connecting...", "Attempting to join " + ssid);

        let args = ["nmcli", "device", "wifi", "connect", ssid];
        
        if (password && password.length > 0) {
            args.push("password", password);
        }
        
        args.push("ifname", root.interfaceName);
        connectProc.exec(args);
    }

    function disconnectFromNetwork(): void {
        console.log("[Wifi] Disconnecting " + root.interfaceName);
        disconnectProc.exec(["nmcli", "device", "disconnect", root.interfaceName]);
        sendNotification("Disconnected", "Disconnected from WiFi network", "network-wireless-disconnected");
    }

    function getWifiStatus(): void {
        wifiStatusProc.running = true;
    }

    // --- PROCESSES ---

    // Dedicated process for notifications
    Process {
        id: notificationProc
    }

    Process {
        id: getNetworks
        running: true
        command: ["nmcli", "-g", "ACTIVE,SIGNAL,FREQ,SSID,BSSID,SECURITY", "d", "w"]
        environment: ({ LANG: "C.UTF-8", LC_ALL: "C.UTF-8" })
        stdout: StdioCollector {
            onStreamFinished: {
                const lines = text.trim().split("\n");
                const parsedMap = new Map();

                lines.forEach(line => {
                    let parts = line.replace(/\\:/g, "__COLON__").split(":");
                    if (parts.length < 4) return;
                    let ssid = parts[3]?.replace(/__COLON__/g, ":") ?? "";
                    if (!ssid) return;

                    let netObj = {
                        active: parts[0] === "yes",
                        strength: parseInt(parts[1]) || 0,
                        frequency: parseInt(parts[2]) || 0,
                        ssid: ssid,
                        bssid: parts[4]?.replace(/__COLON__/g, ":") ?? "",
                        security: parts[5] ?? ""
                    };

                    // Deduplication: Prioritize active network or strongest signal strength
                    if (!parsedMap.has(ssid)) {
                        parsedMap.set(ssid, netObj);
                    } else {
                        let existing = parsedMap.get(ssid);
                        if (netObj.active) parsedMap.set(ssid, netObj);
                        else if (!existing.active && netObj.strength > existing.strength) {
                            parsedMap.set(ssid, netObj);
                        }
                    }
                });

                const finalNetworks = Array.from(parsedMap.values());
                const currentList = root.networks;

                // Remove outdated networks
                const toRemove = currentList.filter(old => !finalNetworks.find(n => n.ssid === old.ssid));
                toRemove.forEach(item => {
                    let idx = currentList.indexOf(item);
                    if (idx !== -1) currentList.splice(idx, 1);
                    item.destroy();
                });

                // Add or update networks
                finalNetworks.forEach(netData => {
                    let match = currentList.find(n => n.ssid === netData.ssid);
                    if (match) match.lastIpcObject = netData;
                    else currentList.push(apComp.createObject(root, { lastIpcObject: netData }));
                });
            }
        }
    }

    Process {
        id: connectProc
        // Handle notification based on exit code
        onExited: (exitCode) => {
            getNetworks.running = true;
            if (exitCode === 0) {
                sendNotification("Connection Successful", "Connected to the network.", "network-wireless-connected");
            } else {
                sendNotification("Connection Failed", "Could not connect. Check credentials or signal.", "network-error");
            }
        }
        stderr: StdioCollector {
            onStreamFinished: { if (text.trim().length > 0) console.error("[Wifi Connect Error]: " + text); }
        }
    }

    Process {
        id: disconnectProc
        stdout: SplitParser { onRead: getNetworks.running = true }
        stderr: StdioCollector {
            onStreamFinished: console.error("[Wifi Disconnect Error]: " + text)
        }
    }

    Process {
        id: wifiStatusProc
        running: true
        command: ["nmcli", "radio", "wifi"]
        stdout: StdioCollector {
            onStreamFinished: root.wifiEnabled = (text.trim() === "enabled")
        }
    }

    Process {
        id: enableWifiProc
        onExited: { root.getWifiStatus(); getNetworks.running = true; }
    }

    Process {
        id: rescanProc
        command: ["nmcli", "dev", "wifi", "list", "--rescan", "yes"]
        onExited: getNetworks.running = true
    }

    component AccessPoint: QtObject {
        required property var lastIpcObject
        readonly property string ssid: lastIpcObject.ssid
        readonly property string bssid: lastIpcObject.bssid
        readonly property int strength: lastIpcObject.strength
        readonly property int frequency: lastIpcObject.frequency
        readonly property bool active: lastIpcObject.active
        readonly property string security: lastIpcObject.security
        readonly property bool isSecure: security.length > 0
    }

    Component { id: apComp; AccessPoint {} }
}

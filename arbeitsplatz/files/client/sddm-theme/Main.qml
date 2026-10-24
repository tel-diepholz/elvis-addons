// ELVIS Arbeitsplatz – Anmeldemaske (SDDM, Qt 5). Benutzer und Einsatz kommen von elvis-clientd (127.0.0.1:7171),
// der auch die PIN prüft und das Profilkonto für Benutzer + Einsatz anlegt. SDDM meldet danach mit dem Einmalpasswort an.
import QtQuick 2.15
import QtQuick.Controls 2.15
import QtQuick.Layouts 1.15
import QtGraphicalEffects 1.15

Rectangle {
    id: root
    width: 1920
    height: 1080
    color: "#0b3f91"

    readonly property string service: "http://127.0.0.1:7171"
    readonly property real u: Math.max(0.75, Math.min(width / 1920, height / 1080))
    property var info: null
    property bool serviceUp: true
    property int selectedId: -1
    property var selected: null
    property bool busy: false
    property string message: ""
    property int sessionIndex: sessionModel.lastIndex

    // Sitzung „Plasma (X11)“ suchen
    Repeater {
        model: sessionModel
        delegate: Item {
            Component.onCompleted: if (model.file === "plasma.desktop") root.sessionIndex = index
        }
    }

    function request(method, path, body, done) {
        var x = new XMLHttpRequest()
        x.onreadystatechange = function () {
            if (x.readyState !== XMLHttpRequest.DONE) return
            var data = null
            try { data = JSON.parse(x.responseText) } catch (e) {}
            done(x.status, data)
        }
        x.open(method, service + path)
        if (body) x.setRequestHeader("Content-Type", "application/json")
        x.send(body ? JSON.stringify(body) : null)
    }

    function refresh() {
        request("GET", "/state", null, function (status, data) {
            serviceUp = status === 200
            if (status !== 200) return
            info = data
            var keep = -1
            users.clear()
            var q = search.text.trim().toLowerCase()
            for (var i = 0; i < data.users.length; i++) {
                var x = data.users[i]
                var full = x.firstName + " " + x.lastName
                if (q && full.toLowerCase().indexOf(q) < 0) continue
                users.append({ uid: x.id, name: full, initials: (x.firstName.charAt(0) + x.lastName.charAt(0)).toUpperCase(), offlineReady: x.offlineReady })
                if (x.id === selectedId) { keep = users.count - 1; selected = copy(users.get(keep)) }
            }
            userList.currentIndex = keep
            if (keep < 0 && selectedId >= 0 && !q) { selectedId = -1; selected = null }
        })
    }

    // Eintrag aus dem ListModel kopieren (die Liste wird bei jeder Aktualisierung neu gefüllt)
    function copy(e) { return { uid: e.uid, name: e.name, initials: e.initials, offlineReady: e.offlineReady } }

    function choose(i) {
        selectedId = users.get(i).uid
        selected = copy(users.get(i))
        message = ""
        pin.text = ""
        pin.forceActiveFocus()
    }

    function submit() {
        if (!selected || pin.text.length !== 4 || busy) return
        busy = true
        message = ""
        request("POST", "/login", { userId: selectedId, pin: pin.text }, function (status, data) {
            if (status === 200) {
                message = data.offline ? "Offline-Anmeldung …" : "Anmeldung …"
                sddm.login(data.account, data.otp, sessionIndex)
            } else {
                busy = false
                pin.text = ""
                message = data && data.error ? data.error : "Dienst nicht erreichbar – bitte kurz warten"
                pin.forceActiveFocus()
            }
        })
    }

    Connections {
        target: sddm
        function onLoginFailed() { busy = false; pin.text = ""; message = "Anmeldung fehlgeschlagen – bitte erneut versuchen" }
    }

    Timer { interval: 5000; running: true; repeat: true; triggeredOnStart: true; onTriggered: refresh() }

    ListModel { id: users }

    // --- Hintergrund ---

    Image {
        id: wallpaper
        anchors.fill: parent
        source: config.background || "background.svg"
        fillMode: Image.PreserveAspectCrop
        sourceSize.width: 1920
        visible: false
    }
    FastBlur { anchors.fill: parent; source: wallpaper; radius: 48 }
    Rectangle { anchors.fill: parent; color: "#33000000" }

    // --- Oben: Einsatz und Uhr ---

    Rectangle {
        id: banner
        anchors { top: parent.top; horizontalCenter: parent.horizontalCenter; topMargin: 28 * u }
        radius: 10 * u
        color: info && info.incident ? "#e6c62828" : "#cc1f2937"
        width: bannerText.implicitWidth + 48 * u
        height: bannerText.implicitHeight + 20 * u
        visible: !!info
        Text {
            id: bannerText
            anchors.centerIn: parent
            color: "white"
            font.pixelSize: 20 * u
            font.weight: Font.DemiBold
            text: !info ? "" : info.revoked ? "Arbeitsplatz in ELVIS gesperrt – bitte neu installieren"
                : info.incident ? "Einsatz: " + [info.incident.keyword, info.incident.title].filter(Boolean).join(" ") + "  (ID " + info.incident.id + ")"
                : "Kein Einsatz aufgelegt"
        }
    }

    Column {
        anchors { top: parent.top; right: parent.right; topMargin: 24 * u; rightMargin: 32 * u }
        Text { id: clock; color: "white"; font.pixelSize: 44 * u; font.weight: Font.Light; anchors.right: parent.right }
        Text { id: date; color: "#e5ffffff"; font.pixelSize: 16 * u; anchors.right: parent.right }
        Timer {
            interval: 1000; running: true; repeat: true; triggeredOnStart: true
            onTriggered: { var d = new Date(); clock.text = Qt.formatTime(d, "hh:mm"); date.text = Qt.formatDate(d, "dddd, d. MMMM yyyy") }
        }
    }

    // --- Mitte: gewählter Benutzer und PIN ---

    Column {
        anchors.centerIn: parent
        spacing: 18 * u
        width: 420 * u

        Rectangle {
            width: 168 * u; height: width; radius: width / 2
            anchors.horizontalCenter: parent.horizontalCenter
            color: selected ? "#1a73e8" : "#55ffffff"
            border.color: "#aaffffff"; border.width: 2
            Text {
                anchors.centerIn: parent
                color: "white"
                font.pixelSize: 64 * u
                text: selected ? selected.initials : "?"
            }
        }
        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            color: "white"
            font.pixelSize: 30 * u
            text: selected ? selected.name : (serviceUp ? "Benutzer unten links wählen" : "Anmeldedienst startet …")
        }

        TextField {
            id: pin
            visible: !!selected
            enabled: !busy && !(info && info.revoked)
            anchors.horizontalCenter: parent.horizontalCenter
            width: 280 * u
            height: 52 * u
            echoMode: TextInput.Password
            passwordCharacter: "●"
            maximumLength: 4
            inputMethodHints: Qt.ImhDigitsOnly
            validator: RegularExpressionValidator { regularExpression: /[0-9]{0,4}/ }
            horizontalAlignment: TextInput.AlignHCenter
            font.pixelSize: 26 * u
            font.letterSpacing: 10 * u
            placeholderText: "PIN"
            placeholderTextColor: "#99ffffff"
            color: "white"
            background: Rectangle { radius: 8 * u; color: "#40000000"; border.color: pin.activeFocus ? "#ffffff" : "#80ffffff"; border.width: 1 }
            onTextChanged: if (text.length === 4) submit()
            Keys.onEscapePressed: { text = ""; message = "" }
        }

        Text {
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
            color: busy ? "white" : "#ffd7d7"
            font.pixelSize: 17 * u
            text: message || (selected && info && !info.online && !selected.offlineReady
                ? "ELVIS ist nicht erreichbar. Offline können sich nur Benutzer anmelden, die sich an diesem Gerät schon angemeldet haben." : "")
        }

        Text {
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
            visible: !!selected && !message
            color: "#ccffffff"
            font.pixelSize: 14 * u
            text: info && info.incident
                ? "Ihre Anpassungen am Desktop gelten nur für diesen Einsatz."
                : "Ohne Einsatz gelten Ihre Anpassungen nur bis zum nächsten Einsatz."
        }
    }

    // --- Unten links: Benutzerliste mit Suche ---

    Rectangle {
        anchors { left: parent.left; bottom: parent.bottom; leftMargin: 24 * u; bottomMargin: 24 * u }
        width: 340 * u
        height: Math.min(parent.height * 0.55, 64 * u + Math.max(1, users.count) * 56 * u)
        radius: 10 * u
        color: "#59000000"

        TextField {
            id: search
            anchors { top: parent.top; left: parent.left; right: parent.right; margins: 10 * u }
            height: 40 * u
            placeholderText: "Name suchen …"
            placeholderTextColor: "#99ffffff"
            color: "white"
            font.pixelSize: 16 * u
            background: Rectangle { radius: 6 * u; color: "#33ffffff" }
            onTextChanged: refresh()
            Keys.onDownPressed: { if (users.count) { userList.forceActiveFocus(); userList.currentIndex = 0 } }
            Keys.onReturnPressed: if (users.count === 1) choose(0)
        }

        ListView {
            id: userList
            anchors { top: search.bottom; left: parent.left; right: parent.right; bottom: parent.bottom; margins: 6 * u; topMargin: 8 * u }
            clip: true
            model: users
            currentIndex: -1
            ScrollBar.vertical: ScrollBar {}
            Keys.onReturnPressed: if (currentIndex >= 0) choose(currentIndex)
            delegate: ItemDelegate {
                width: userList.width
                height: 52 * u
                highlighted: model.uid === root.selectedId
                onClicked: choose(index)
                background: Rectangle { radius: 6 * u; color: highlighted ? "#661a73e8" : (hovered ? "#26ffffff" : "transparent") }
                contentItem: RowLayout {
                    spacing: 12 * u
                    Rectangle {
                        Layout.preferredWidth: 36 * u; Layout.preferredHeight: 36 * u; radius: 18 * u
                        color: "#1a73e8"
                        Text { anchors.centerIn: parent; color: "white"; font.pixelSize: 15 * u; text: model.initials }
                    }
                    Text {
                        Layout.fillWidth: true
                        elide: Text.ElideRight
                        color: (info && !info.online && !model.offlineReady) ? "#80ffffff" : "white"
                        font.pixelSize: 17 * u
                        text: model.name
                    }
                }
            }
            Text {
                anchors.centerIn: parent
                visible: users.count === 0
                color: "#ccffffff"
                font.pixelSize: 15 * u
                width: userList.width - 24 * u
                wrapMode: Text.WordWrap
                horizontalAlignment: Text.AlignHCenter
                text: !info ? "" : info.revoked ? "Gesperrt" : search.text ? "Kein Treffer" : info.lastSync ? "Keine Benutzer"
                    : "Noch keine Verbindung zu ELVIS" + (info.error ? "\n" + info.error : "")
            }
        }
    }

    // --- Unten rechts: Verbindung und Ein/Aus ---

    Row {
        anchors { right: parent.right; bottom: parent.bottom; rightMargin: 24 * u; bottomMargin: 24 * u }
        spacing: 10 * u

        Rectangle {
            height: 40 * u
            width: status.implicitWidth + 28 * u
            radius: 20 * u
            color: "#59000000"
            Text {
                id: status
                anchors.centerIn: parent
                color: "white"
                font.pixelSize: 14 * u
                text: !serviceUp ? "Dienst nicht erreichbar"
                    : !info ? "" : (info.online ? "● ELVIS verbunden" : "○ Offline" + (info.error ? ": " + info.error : ""))
                      + (info.workstation ? "  ·  " + info.workstation.name : "")
            }
        }
        Repeater {
            model: [
                { label: "Neu starten", action: "reboot", ok: sddm.canReboot },
                { label: "Ausschalten", action: "powerOff", ok: sddm.canPowerOff }
            ]
            delegate: Button {
                visible: modelData.ok
                height: 40 * u
                text: modelData.label
                font.pixelSize: 14 * u
                onClicked: modelData.action === "reboot" ? sddm.reboot() : sddm.powerOff()
                contentItem: Text { text: parent.text; font: parent.font; color: "white"; horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter }
                background: Rectangle { radius: 20 * u; color: parent.hovered ? "#80000000" : "#59000000" }
            }
        }
    }

    // --- Update läuft: Anmeldung gesperrt ---

    Rectangle {
        anchors.fill: parent
        visible: !!(info && info.updating)
        color: "#e60b2a52"
        MouseArea { anchors.fill: parent; hoverEnabled: true } // Eingaben darunter abfangen
        Column {
            anchors.centerIn: parent
            spacing: 18 * u
            width: Math.min(parent.width - 80 * u, 760 * u)
            BusyIndicator { anchors.horizontalCenter: parent.horizontalCenter; running: parent.visible; width: 72 * u; height: width }
            Text {
                width: parent.width
                horizontalAlignment: Text.AlignHCenter
                color: "white"
                font.pixelSize: 34 * u
                text: "Update läuft"
            }
            Text {
                width: parent.width
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.WordWrap
                color: "#e5ffffff"
                font.pixelSize: 20 * u
                text: (info && info.updating ? info.updating.message : "") + "\n\nBitte das Notebook nicht ausschalten und am Netzteil lassen. Danach ist die Anmeldung wieder möglich; falls nötig, startet das Notebook selbst neu."
            }
        }
    }

    Component.onCompleted: search.forceActiveFocus()
}

// ELVIS Arbeitsplatz: Aufbau jedes neuen Profils im Stil von Windows 11 –
// eine Taskleiste unten, Start und Programme in der Mitte, Infobereich und Uhr rechts.

var panel = new Panel;
panel.location = "bottom";
panel.height = 2 * Math.floor(gridUnit * 2.4 / 2);
panel.hiding = "none";

panel.addWidget("org.kde.plasma.panelspacer");

var start = panel.addWidget("org.kde.plasma.kickoff");
start.currentConfigGroup = ["General"];
start.writeConfig("icon", "/usr/share/elvis/start.svg");
start.writeConfig("favoritesPortedToKAstats", "true");
start.writeConfig("favorites", "applications:elvis.desktop,applications:firefox.desktop,applications:org.kde.dolphin.desktop,applications:libreoffice-writer.desktop,applications:libreoffice-calc.desktop,applications:org.kde.okular.desktop,applications:systemsettings.desktop");
start.writeConfig("primaryActions", "1");
start.writeConfig("showActionButtonCaptions", "false");

var tasks = panel.addWidget("org.kde.plasma.icontasks");
tasks.currentConfigGroup = ["General"];
tasks.writeConfig("launchers", "applications:elvis.desktop,applications:firefox.desktop,applications:org.kde.dolphin.desktop,applications:libreoffice-writer.desktop");
tasks.writeConfig("fill", "false");
tasks.writeConfig("iconSpacing", "2");
tasks.writeConfig("indicateAudioStreams", "true");

panel.addWidget("org.kde.plasma.panelspacer");

panel.addWidget("org.kde.plasma.systemtray");

var clock = panel.addWidget("org.kde.plasma.digitalclock");
clock.currentConfigGroup = ["Appearance"];
clock.writeConfig("showDate", "true");
clock.writeConfig("dateFormat", "shortDate");
clock.writeConfig("use24hFormat", "2");

panel.addWidget("org.kde.plasma.showdesktop");

// Hintergrund ELVIS, ohne Symbole auf dem Desktop außer dem Ordner Schreibtisch
var desktops = desktopsForActivity(currentActivity());
for (var i = 0; i < desktops.length; i++) {
    var d = desktops[i];
    d.wallpaperPlugin = "org.kde.image";
    d.currentConfigGroup = ["Wallpaper", "org.kde.image", "General"];
    d.writeConfig("Image", "file:///usr/share/wallpapers/ELVIS/");
    d.writeConfig("FillMode", "2");
}

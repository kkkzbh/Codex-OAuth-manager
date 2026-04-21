pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Shapes
import QtQuick.Layouts

import org.kde.kirigami as Kirigami
import org.kde.plasma.plasmoid

Item {
    id: compactRoot

    required property PlasmoidItem rootItem
    readonly property int workerCount: compactRoot.rootItem.workerCount
    readonly property bool busy: compactRoot.workerCount > 0
    readonly property int basePeriodMs: compactRoot.rootItem.basePeriodMs

    // Spin period: base / log2(1 + n). n=1 → base, n=3 → base/2, n=7 → base/3, n=15 → base/4.
    readonly property int spinDurationMs: {
        if (compactRoot.workerCount <= 0) return 0;
        const factor = Math.log(1 + compactRoot.workerCount) / Math.log(2);
        return Math.max(120, Math.round(compactRoot.basePeriodMs / factor));
    }

    Layout.minimumWidth: Kirigami.Units.gridUnit * 1.4
    Layout.minimumHeight: Kirigami.Units.gridUnit * 1.4
    Layout.preferredWidth: Layout.minimumWidth
    Layout.preferredHeight: Layout.minimumHeight
    implicitWidth: Layout.minimumWidth
    implicitHeight: Layout.minimumHeight

    Item {
        id: circle
        anchors.centerIn: parent
        readonly property real diameter: Math.min(parent.width, parent.height) - Kirigami.Units.smallSpacing
        width: diameter
        height: diameter

        // Filled indicator light (green when idle, red when busy).
        Rectangle {
            id: light
            anchors.fill: parent
            radius: width / 2
            color: compactRoot.busy ? "#e74c3c" : "#2ecc71"
            border.color: Qt.darker(color, 1.25)
            border.width: 1

            Behavior on color {
                ColorAnimation { duration: 200 }
            }
        }

        // White rotating arc ring (visible only when busy).
        Shape {
            id: arcShape
            anchors.fill: parent
            antialiasing: true
            visible: compactRoot.busy
            layer.enabled: true
            layer.samples: 8

            transformOrigin: Item.Center

            ShapePath {
                strokeColor: "white"
                strokeWidth: Math.max(1.5, circle.diameter * 0.09)
                fillColor: "transparent"
                capStyle: ShapePath.RoundCap

                readonly property real cx: arcShape.width / 2
                readonly property real cy: arcShape.height / 2
                readonly property real r: (circle.diameter / 2) - (strokeWidth / 2) - 0.5

                // Draw a ~200° arc starting at the top-left.
                startX: cx + r * Math.cos((-130) * Math.PI / 180)
                startY: cy + r * Math.sin((-130) * Math.PI / 180)

                PathArc {
                    x: arcShape.width / 2 + ((circle.diameter / 2) - (Math.max(1.5, circle.diameter * 0.09) / 2) - 0.5) * Math.cos(70 * Math.PI / 180)
                    y: arcShape.height / 2 + ((circle.diameter / 2) - (Math.max(1.5, circle.diameter * 0.09) / 2) - 0.5) * Math.sin(70 * Math.PI / 180)
                    radiusX: (circle.diameter / 2) - (Math.max(1.5, circle.diameter * 0.09) / 2) - 0.5
                    radiusY: (circle.diameter / 2) - (Math.max(1.5, circle.diameter * 0.09) / 2) - 0.5
                    useLargeArc: true
                    direction: PathArc.Clockwise
                }
            }
        }

        RotationAnimator {
            id: spinAnimator
            target: arcShape
            from: 0
            to: 360
            loops: Animation.Infinite
            running: compactRoot.busy && compactRoot.spinDurationMs > 0
            duration: Math.max(120, compactRoot.spinDurationMs)
        }

        // Restart animator whenever duration changes so new speed takes effect.
        Connections {
            target: compactRoot
            function onSpinDurationMsChanged() {
                if (!compactRoot.busy) {
                    spinAnimator.stop();
                    arcShape.rotation = 0;
                    return;
                }
                spinAnimator.stop();
                spinAnimator.duration = Math.max(120, compactRoot.spinDurationMs);
                spinAnimator.start();
            }
            function onBusyChanged() {
                if (!compactRoot.busy) {
                    spinAnimator.stop();
                    arcShape.rotation = 0;
                }
            }
        }

        // Centered worker count (shown only when busy).
        Text {
            anchors.centerIn: parent
            text: String(compactRoot.workerCount)
            visible: compactRoot.busy
            color: "white"
            font.bold: true
            font.pixelSize: Math.max(10, circle.diameter * 0.45)
            renderType: Text.QtRendering
        }
    }

    MouseArea {
        id: mouseArea
        anchors.fill: parent
        hoverEnabled: true
        onClicked: compactRoot.rootItem.expanded = !compactRoot.rootItem.expanded
    }
}

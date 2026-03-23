pragma ComponentBehavior: Bound

import QtQuick

import org.kde.kirigami as Kirigami

Item {
    id: root

    property string valueText: "--"
    property color textColor: Kirigami.Theme.textColor
    property int fontPixelSize: 18
    property int fontWeight: Font.DemiBold
    property string fontFamily: Kirigami.Theme.defaultFont.family

    property bool initialized: false
    property bool animating: false
    property string displayText: String(valueText || "--")
    property string outgoingText: displayText
    property string pendingText: displayText
    property real rollProgress: 1

    readonly property font numberFont: Qt.font({
        family: fontFamily,
        pixelSize: fontPixelSize,
        weight: fontWeight
    })
    readonly property int slotCount: Math.max(1, Math.max(displayText.length, outgoingText.length))
    readonly property real digitWidth: Math.max(1, Math.ceil(fontMetrics.advanceWidth("0")))
    readonly property real separatorWidth: Math.max(1, Math.ceil(fontMetrics.advanceWidth(",")))
    readonly property real lineHeight: Math.max(fontMetrics.height, height)

    implicitWidth: Math.max(1, Math.ceil(totalWidth(slotCount)))
    implicitHeight: Math.max(1, Math.ceil(fontMetrics.height))
    width: implicitWidth
    height: implicitHeight

    function isTokenValue(value) {
        return /^[\d,]+$/.test(String(value))
    }

    function isDigitChar(glyph) {
        return /^[0-9]$/.test(String(glyph))
    }

    function alignedChars(value, count) {
        const glyphs = String(value || "").split("");
        const padding = Math.max(count - glyphs.length, 0);
        return Array(padding).fill(" ").concat(glyphs);
    }

    function slotWidthForChar(glyph) {
        return glyph === "," ? separatorWidth : digitWidth;
    }

    function totalWidth(count) {
        const currentChars = alignedChars(displayText, count);
        const nextChars = alignedChars(outgoingText, count);
        let sum = 0;

        for (let i = 0; i < count; i += 1) {
            const currentChar = currentChars[i] || " ";
            const nextChar = nextChars[i] || " ";
            sum += Math.max(slotWidthForChar(currentChar), slotWidthForChar(nextChar));
        }

        return sum;
    }

    function digitRankFromRight(glyphs, index) {
        let rank = 0;
        for (let i = glyphs.length - 1; i > index; i -= 1) {
            if (isDigitChar(glyphs[i])) {
                rank += 1;
            }
        }
        return rank;
    }

    function reelSequence(fromChar, toChar) {
        const fromDigit = Number(fromChar);
        const toDigit = Number(toChar);
        const delta = (toDigit - fromDigit + 10) % 10;
        const turns = delta + 10;
        const sequence = [];

        for (let step = 0; step <= turns; step += 1) {
            sequence.push(String((fromDigit + step) % 10));
        }

        return sequence;
    }

    function canvasFontSpec() {
        const family = fontFamily && fontFamily.length > 0 ? `"${fontFamily}"` : "sans-serif";
        return `${fontWeight} ${fontPixelSize}px ${family}`;
    }

    function applyImmediate(nextValue) {
        rollAnimation.stop();
        animating = false;
        displayText = nextValue;
        outgoingText = nextValue;
        pendingText = nextValue;
        rollProgress = 1;
        numberCanvas.requestPaint();
    }

    function startRoll(nextValue) {
        outgoingText = displayText;
        displayText = nextValue;
        animating = true;
        rollProgress = 0;
        numberCanvas.requestPaint();
        rollAnimation.restart();
    }

    function syncValue() {
        const nextValue = String(valueText || "--");
        pendingText = nextValue;

        if (!initialized) {
            initialized = true;
            applyImmediate(nextValue);
            return;
        }

        if (animating || nextValue === displayText) {
            return;
        }

        if (!isTokenValue(displayText) || !isTokenValue(nextValue)) {
            applyImmediate(nextValue);
            return;
        }

        startRoll(nextValue);
    }

    onValueTextChanged: syncValue()
    onRollProgressChanged: numberCanvas.requestPaint()
    onTextColorChanged: numberCanvas.requestPaint()
    onFontPixelSizeChanged: numberCanvas.requestPaint()
    onFontWeightChanged: numberCanvas.requestPaint()
    onFontFamilyChanged: numberCanvas.requestPaint()
    onWidthChanged: numberCanvas.requestPaint()
    onHeightChanged: numberCanvas.requestPaint()

    Component.onCompleted: syncValue()

    FontMetrics {
        id: fontMetrics
        font: root.numberFont
    }

    Canvas {
        id: numberCanvas
        anchors.fill: parent
        renderStrategy: Canvas.Cooperative

        function drawCharacter(context, glyph, x, baselineY, width, alpha) {
            if (!glyph || alpha <= 0) {
                return;
            }

            context.save();
            context.globalAlpha = alpha;
            context.fillStyle = root.textColor;
            context.fillText(glyph, x, baselineY, width);
            context.restore();
        }

        function alphaForOffset(offset) {
            const normalized = Math.min(Math.abs(offset) / root.lineHeight, 1.2);
            return Math.max(0.14, 1 - (normalized * 0.72));
        }

        function drawStaticSlot(context, glyph, x, baselineY, width) {
            if (glyph === " ") {
                return;
            }

            drawCharacter(context, glyph, x, baselineY, width, 1);
        }

        function drawRollingSlot(context, fromChar, toChar, x, topY, width, phase) {
            const sequence = root.reelSequence(fromChar, toChar);
            const centerBaseline = topY + fontMetrics.ascent;
            const offsetY = phase * (sequence.length - 1) * root.lineHeight;

            context.save();
            context.beginPath();
            context.rect(x, 0, width, height);
            context.clip();

            for (let i = 0; i < sequence.length; i += 1) {
                const baselineY = centerBaseline - (i * root.lineHeight) + offsetY;
                const centerOffset = baselineY - centerBaseline;
                drawCharacter(context, sequence[i], x, baselineY, width, alphaForOffset(centerOffset));
            }

            context.restore();
        }

        onPaint: {
            const context = getContext("2d");
            context.clearRect(0, 0, width, height);
            context.font = root.canvasFontSpec();
            context.textAlign = "left";
            context.textBaseline = "alphabetic";

            const currentChars = root.alignedChars(root.outgoingText, root.slotCount);
            const targetChars = root.alignedChars(root.displayText, root.slotCount);
            const topY = (height - fontMetrics.height) / 2;
            let x = 0;

            for (let i = 0; i < root.slotCount; i += 1) {
                const fromChar = currentChars[i] || " ";
                const toChar = targetChars[i] || " ";
                const slotWidth = Math.max(root.slotWidthForChar(fromChar), root.slotWidthForChar(toChar));

                if (
                    root.animating &&
                    root.isDigitChar(fromChar) &&
                    root.isDigitChar(toChar) &&
                    fromChar !== toChar
                ) {
                    const rank = root.digitRankFromRight(targetChars, i);
                    const delay = Math.min(rank * 0.055, 0.28);
                    const localPhase = Math.max(0, Math.min(1, (root.rollProgress - delay) / (1 - delay)));
                    drawRollingSlot(context, fromChar, toChar, x, topY, slotWidth, localPhase);
                } else {
                    drawStaticSlot(context, toChar === " " ? fromChar : toChar, x, topY + fontMetrics.ascent, slotWidth);
                }

                x += slotWidth;
            }
        }
    }

    NumberAnimation on rollProgress {
        id: rollAnimation
        from: 0
        to: 1
        duration: 420
        easing.type: Easing.OutQuart

        onFinished: {
            root.animating = false;
            root.rollProgress = 1;
            numberCanvas.requestPaint();

            if (root.pendingText !== root.displayText) {
                if (!root.isTokenValue(root.pendingText)) {
                    root.applyImmediate(root.pendingText);
                } else {
                    root.startRoll(root.pendingText);
                }
            }
        }
    }
}

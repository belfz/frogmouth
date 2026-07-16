# Slice a VID.STAB ASCII local-motion file for a zero-based [start, end)
# source-frame range. This is intentionally a spike helper: T01 demonstrates
# that row slicing alone does not preserve the parent stabilization result.

/^Frame / {
    frame = $2 + 0
    if (frame >= start + 1 && frame <= end) {
        localFrame = frame - start
        sub("^Frame " frame, "Frame " localFrame)
        print
    }
    next
}

{ print }

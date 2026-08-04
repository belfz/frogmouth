(() => {
  "use strict";

  const chapters = [...document.querySelectorAll(".chapter")];
  const navButtons = [...document.querySelectorAll(".chapter-link")];
  const title = document.querySelector("#topbar-title");
  const progressLabel = document.querySelector("#progress-label");
  const progressPercent = document.querySelector("#progress-percent");
  const progressBar = document.querySelector("#progress-bar");
  const chapterPosition = document.querySelector("#chapter-position");
  const previousButton = document.querySelector("#previous-button");
  const nextButton = document.querySelector("#next-button");
  const toast = document.querySelector("#toast");
  let activeIndex = Math.max(0, chapters.findIndex((chapter) => chapter.id === location.hash.slice(1)));
  let toastTimer;

  const architectureDetails = {
    app: {
      type: "Executable target · presentation",
      title: "FrogmouthApp",
      body: "The native macOS shell. SwiftUI declares the visual hierarchy while a small set of AppKit and AVKit bridges handle platform-specific behavior.",
      bullets: [
        "FrogmouthApp is the composition root and command-menu owner.",
        "ApplicationViewModel validates FFmpeg once at startup.",
        "ProjectDocumentViewModel coordinates one active document session.",
        "Views render published snapshots and send user intentions back."
      ],
      path: "Sources/FrogmouthApp"
    },
    core: {
      type: "Library target · domain and services",
      title: "FrogmouthCore",
      body: "The testable center of the app: exact time, project schema, editing commands, persistence, source resolution, preview composition, stabilization, cache, export planning, execution, and validation.",
      bullets: [
        "Value types model durable decisions.",
        "Actors isolate document, autosave, cache, and thumbnail state.",
        "Protocols create seams around I/O and subprocesses.",
        "No dependency points back to FrogmouthApp."
      ],
      path: "Sources/FrogmouthCore"
    },
    ffmpeg: {
      type: "External process · heavy media work",
      title: "FFmpeg + ffprobe",
      body: "A separately installed and version-validated tool. Frogmouth constructs argument arrays and filter graphs, launches the executable with Foundation Process, parses progress, and supports cancellation.",
      bullets: [
        "Tested versions: 7.1.1 and 8.1.2.",
        "Required: vidstabdetect, vidstabtransform, hevc_videotoolbox.",
        "Never invoked through a shell string.",
        "Every final export is reinspected before publication."
      ],
      path: "Sources/FrogmouthCore/FFmpegRunner.swift"
    },
    apple: {
      type: "System frameworks · native platform",
      title: "Apple frameworks",
      body: "The app deliberately embraces macOS rather than abstracting it away. Apple APIs own interactive playback, UI integration, exact media types, hashing, and file/process primitives.",
      bullets: [
        "SwiftUI + Combine: views and observable state.",
        "AppKit: panels, windows, Finder, pasteboard, native bridges.",
        "AVFoundation + AVKit: inspection, preview, player, thumbnails.",
        "CoreMedia + CryptoKit: exact time boundaries and cache hashes."
      ],
      path: "Package.swift"
    },
    benchmark: {
      type: "Executable target · regression signal",
      title: "FrogmouthBenchmark",
      body: "A repeatable 50-clip workload measures structural editing and real-media surfaces. It is deliberately separate from the correctness suite.",
      bullets: [
        "JSON encode/decode and project open/autosave.",
        "Timeline indexing, trim feedback, zoom/scroll math.",
        "Render-plan and AV composition construction.",
        "Cold/cached thumbnails and resident memory."
      ],
      path: "Sources/FrogmouthBenchmark/main.swift"
    }
  };

  const flows = {
    startup: {
      summary: "Startup is a gate: the editor is unavailable until one supported FFmpeg installation proves its version, stabilization filters, and VideoToolbox encoder.",
      steps: [
        ["Composition root", "Create one DiagnosticLogStore plus the application and document view models.", "FrogmouthApp.swift"],
        ["Bootstrap", "ApplicationViewModel runs exactly once and asks an injected FFmpegLocating implementation to validate.", "ApplicationViewModel.swift"],
        ["Tool probe", "FFmpegLocator checks known paths or an override, parses the exact version, filters, and encoders.", "FFmpegSupport.swift"],
        ["UI gate", "RootView switches from progress/setup instructions to the project startup/editor surface.", "RootView.swift"]
      ]
    },
    import: {
      summary: "Import converts external file facts into a durable MediaAsset, then optionally appends a TimelineClip. The source itself remains untouched.",
      steps: [
        ["User intent", "Drop URLs or choose NSOpenPanel. The main-actor coordinator normalizes the request.", "ProjectDocumentViewModel.swift"],
        ["Inspect + fingerprint", "AVFoundation reads exact media facts while MediaFingerprinter identifies the current source bytes.", "ProjectMedia.swift"],
        ["Compatibility", "The first clip establishes timeline format; later sources must match colour rules and are conformed for size/rate/audio.", "ProjectMedia.swift"],
        ["Commit", "ProjectCommand.importMedia and appendClip validate, enter history, schedule autosave, and trigger preview refresh.", "TimelineEditing.swift"]
      ]
    },
    edit: {
      summary: "A durable edit is a command applied to a value snapshot. It either produces one fully valid ProjectState or changes nothing.",
      steps: [
        ["Gesture", "Toolbar, keyboard, timeline drag, trim handle, or inspector produces an intention.", "SequenceTimelineView.swift"],
        ["Coordinate", "ProjectDocumentViewModel maps UI coordinates/selection into exact IDs, frames, and source ranges.", "ProjectDocumentViewModel.swift"],
        ["Apply command", "ProjectEditor applies ProjectCommand to a candidate value and rebuilds TimelineIndex to enforce invariants.", "TimelineEditing.swift"],
        ["Publish", "ProjectDocumentSession records history, schedules autosave, and returns one coherent snapshot to the UI.", "ProjectPersistence.swift"]
      ]
    },
    preview: {
      summary: "Preview rebuilds an AVFoundation composition off the main actor, then atomically installs the newest result into AVPlayer.",
      steps: [
        ["Snapshot", "PlaybackCoordinator receives ProjectState, resolved URLs, stabilized proxy overrides, and the frame to preserve.", "PlaybackCoordinator.swift"],
        ["Compose", "A detached task builds video/audio tracks, aspect-fit transforms, fades, and an exact segment map.", "PlaybackComposition.swift"],
        ["Freshness guard", "Cancellation plus a UUID generation prevents an older build from replacing newer intent.", "PlaybackCoordinator.swift"],
        ["Play + map", "AVPlayer time is mapped back through PlaybackSegmentMap to timeline frame, clip, and source position.", "PlaybackComposition.swift"]
      ]
    },
    stabilize: {
      summary: "Stabilization is a selected-clip, blocking, cancellable pipeline whose transform analysis and preview are cache-addressed.",
      steps: [
        ["Plan effect", "Append a Steady or Natural Motion pass with nested analysis coverage and a processing revision.", "StabilizationPassPlanner.swift"],
        ["Resolve cache", "Source fingerprint, tool revision, pass chain, and parameters produce identities for transforms and proxy.", "StabilizationStatus.swift"],
        ["Analyze + render", "ClipStabilizationProcessor runs detect and transform commands, reporting phases and respecting cancellation.", "ClipStabilizationProcessor.swift"],
        ["Commit result", "Only complete artifacts enter ProjectCacheStore; the effect command updates the project and preview override.", "ProjectCache.swift"]
      ]
    },
    export: {
      summary: "Export is plan → command → process → inspect → validate → atomic finalize. No intermediate file is allowed to masquerade as success.",
      steps: [
        ["Readiness", "Check every source path and every stabilization status; refuse missing or stale inputs.", "TimelineExport.swift"],
        ["Plan", "TimelineRenderPlanner resolves inputs, clip conformance, effects, exact frames, bitrate, and output facts.", "TimelineRenderPlan.swift"],
        ["Render", "TimelineFFmpegCommandFactory emits argv/filter graph; FFmpegRunner publishes progress and cancellation.", "TimelineFFmpegCommandFactory.swift"],
        ["Prove + finalize", "Reinspect media and provenance, validate against the plan, then atomically replace the destination.", "TimelineExport.swift"]
      ]
    },
    autosave: {
      summary: "Autosave is debounced and actor-isolated. An unsaved new project has no autosave destination; a saved project writes coherent snapshots atomically.",
      steps: [
        ["Mutation", "A successful ProjectCommand changes ProjectEditor.project inside ProjectDocumentSession.", "ProjectPersistence.swift"],
        ["Debounce", "ProjectAutosaveCoordinator cancels an older pending write and waits 750 ms.", "ProjectPersistence.swift"],
        ["Atomic write", "ProjectJSONCodec emits sorted, pretty schema-2 JSON; AtomicProjectFileWriter renames a temporary sibling.", "ProjectPersistence.swift"],
        ["Acknowledge", "The session updates lastSavedProject only for the matching URL/snapshot and publishes modified state.", "ProjectPersistence.swift"]
      ]
    }
  };

  const operations = {
    split: {
      title: "Split one clip at the playhead",
      summary: "A metadata edit: one TimelineClip becomes two adjacent clips. No video is decoded or rendered.",
      cost: "instant · no media files",
      heavy: false,
      layers: [
        ["UI event", "C key or scissors", "The selected clip and playhead produce an exact timeline-frame offset.", "ProjectDocumentViewModel.splitSelectedClip()"],
        ["Domain command", "Map frame → source time", "ProjectCommand.splitClip validates an interior cut and builds left/right source ranges.", "TimelineTimeMapper + TimelineIndex"],
        ["State result", "One snapshot → two clips", "Both inherit stabilization. Left keeps fade-in; right keeps fade-out; the new right clip is selected.", "ProjectEditor + ProjectHistory"],
        ["Preview result", "Recompose in memory", "PlaybackCoordinator rebuilds the AVFoundation composition while preserving the playhead.", "No FFmpeg invocation"]
      ],
      files: [
        ["untouched", "Source video", "read-only; never rewritten"],
        ["persisted", ".frogmouth JSON", "two clip records after save/autosave"],
        ["created", "Atomic save temp", ".project.UUID.tmp exists briefly, then rename"],
        ["untouched", "Media cache", "no new thumbnail/stabilization artifact required"]
      ]
    },
    trim: {
      title: "Drag a clip edge, then release",
      summary: "A two-stage edit: drag feedback is transient; release commits exactly one undoable source-range change.",
      cost: "interactive · no media files",
      heavy: false,
      layers: [
        ["UI event", "Handle drag", "Pixel/frame delta is clamped and mapped to an exact source frame.", "TimelineTrimMapper"],
        ["Transient state", "TrimPreview only", "Pending range changes the presented timeline geometry. History and project JSON do not move yet.", "ProjectDocumentViewModel.TrimPreview"],
        ["Domain commit", "One trim command", "On release, TrimTransaction validates the pending range and records one ProjectHistory snapshot.", "ProjectEditor.commitTrim()"],
        ["Preview result", "Recompose + revalidate", "AVFoundation rebuilds. Existing stabilization remains, but expanding beyond analyzed coverage makes it stale.", "StabilizationStatusResolver"]
      ],
      files: [
        ["untouched", "During drag", "memory only; zero disk writes"],
        ["persisted", ".frogmouth JSON", "updated sourceRange after commit + autosave"],
        ["created", "Atomic save temp", "brief sibling .tmp; removed or renamed"],
        ["untouched", "Source video", "read-only; frames are referenced, not cut"]
      ]
    },
    fade: {
      title: "Add, change, or remove a picture fade",
      summary: "A small persisted decision interpreted twice: as an AVFoundation opacity ramp for preview and an FFmpeg video filter for export.",
      cost: "instant edit · render on preview/export",
      heavy: false,
      layers: [
        ["UI event", "Inspector control", "Enable defaults to 1000 ms; input is parsed as Int64 milliseconds; remove passes nil.", "VideoFadeInspector"],
        ["Domain command", "Validate duration", "Each fade must be positive and fade-in + fade-out cannot exceed clip duration.", "VideoFadePolicy"],
        ["Preview result", "Opacity ramp", "AVMutableVideoCompositionLayerInstruction ramps 0→1 or 1→0 against black.", "PlaybackComposition.swift"],
        ["Export result", "FFmpeg fade filter", "fade=t=in/out is added only to the video branch. Audio is unchanged by this feature.", "TimelineFFmpegCommandFactory.swift"]
      ],
      files: [
        ["untouched", "Source video", "read-only; fade is never baked into it"],
        ["persisted", ".frogmouth JSON", "optional videoFadeIn/videoFadeOut objects"],
        ["created", "Atomic save temp", "brief .tmp during save/autosave"],
        ["untouched", "Edit-time media", "no proxy or cache file just for a fade"]
      ]
    },
    stabilize: {
      title: "Apply Steady or Natural Motion",
      summary: "A real processing operation: analyze motion, render a lightweight proxy, cache both, then commit the effect descriptor.",
      cost: "heavy · blocking + cancellable",
      heavy: true,
      layers: [
        ["UI event", "Apply mode", "StabilizationPassPlanner appends a pass covering the selected clip; the editor enters a blocking progress state.", "ProjectDocumentViewModel.applyStabilization()"],
        ["Cache decision", "Identity lookup", "Source fingerprint, FFmpeg revision, algorithm revision, coverage, mode, and ordered pass chain decide hit vs stale.", "StabilizationStatusResolver"],
        ["FFmpeg work", "Analyze → preview", "vidstabdetect writes .trf; vidstabtransform renders a 1024px HEVC/AAC preview. Stacked passes nest coverage.", "ClipStabilizationProcessor"],
        ["Commit + preview", "Cache then command", "Only complete artifacts enter the managed cache. setStabilizationPasses persists the decision; playback uses the proxy.", "ProjectCacheStore + ProjectEditor"]
      ],
      files: [
        ["created", "Session workspace", "/tmp/frogmouth/UUID/transforms-effect.trf + preview-effect.mp4; always removed"],
        ["cached", "Managed artifacts", "~/Library/Caches/dev.frogmouth.app/projects/…/entries/HASH/artifact + manifest.json"],
        ["persisted", ".frogmouth JSON", "effect ID, mode, analysis coverage, processing revision"],
        ["untouched", "Source video", "read-only input to both FFmpeg passes"]
      ]
    },
    export: {
      title: "Export the complete timeline",
      summary: "The only operation here that creates the user’s final media file. It renders to a hidden partial sibling, validates it, then renames atomically.",
      cost: "heavy · cancellable",
      heavy: true,
      layers: [
        ["UI event", "Choose destination", "Readiness requires present sources and current stabilization transforms.", "TimelineExportReadinessValidator"],
        ["Pure planning", "Project → render plan", "Inputs, exact frames, conformance, effects, bitrate, metadata, and expected output are fixed before execution.", "TimelineRenderPlanner"],
        ["FFmpeg work", "Filter + encode", "One filter graph trims, stabilizes, conforms, fades, concatenates, maps audio, and writes HEVC/AAC.", "TimelineFFmpegCommandFactory + FFmpegRunner"],
        ["Proof + publish", "Inspect then rename", "MediaInspector validates facts and provenance. Hidden flag is cleared; Darwin.rename publishes atomically.", "TimelineExporter + AtomicTimelineExportFileFinalizer"]
      ],
      files: [
        ["created", "Partial export", ".name.frogmouth-UUID.partial.mp4 beside destination; removed on failure/cancel"],
        ["persisted", "Final MP4", "appears only after validation and atomic rename"],
        ["cached", "Stabilization .trf", "existing managed cache inputs are read; proxies are not used for delivery"],
        ["untouched", "Source videos", "read-only FFmpeg inputs; original metadata is inspected"]
      ]
    }
  };

  const routes = {
    editing: {
      primary: "ProjectCommand + ProjectEditor in Sources/FrogmouthCore/TimelineEditing.swift",
      supporting: "ExactTime.swift, TimelineTrimming.swift, TimelinePresentation.swift, then the relevant view-model method",
      tests: "TimelineEditingTests.swift + ExactTimeTests.swift; add render tests if output semantics change"
    },
    ui: {
      primary: "Sources/FrogmouthApp/ProjectEditorShell.swift or SequenceTimelineView.swift",
      supporting: "ProjectDocumentViewModel.swift only when new application state or orchestration is required",
      tests: "Keep domain logic in FrogmouthCore tests; manually verify keyboard, VoiceOver, resizing, and dense timelines"
    },
    preview: {
      primary: "PlaybackComposition.swift for media assembly; PlaybackCoordinator.swift for lifecycle",
      supporting: "NativeVideoPlayer.swift and exact PlaybackSegmentMap behavior",
      tests: "PlaybackCompositionTests.swift + generated media; manually play across cuts and seek boundaries"
    },
    export: {
      primary: "TimelineRenderPlan.swift → TimelineFFmpegCommandFactory.swift → TimelineExport.swift",
      supporting: "QualityPolicy.swift, ColourCompatibility.swift, MediaInspector.swift, FFmpegRunner.swift",
      tests: "TimelineRenderTests.swift + TimelineExportTests.swift; require integration for codec/filter/media changes"
    },
    stabilization: {
      primary: "StabilizationPassPlanner.swift, StabilizationStatus.swift, ClipStabilizationProcessor.swift",
      supporting: "ClipStabilizationCommandFactory.swift + ProjectCache.swift + view-model task lifecycle",
      tests: "ClipStabilizationTests.swift + StabilizationStatusTests.swift; bump processing/cache identity when behavior changes"
    },
    persistence: {
      primary: "ProjectDomain.swift for schema; ProjectPersistence.swift for document lifecycle",
      supporting: "ProjectMedia.swift for resolving/revalidating sources; ProjectCache.swift is never persisted project truth",
      tests: "ProjectDomainTests.swift canonical fixture + ProjectPersistenceTests.swift; require explicit migration policy"
    },
    media: {
      primary: "ProjectMedia.swift and MediaInspector.swift",
      supporting: "ColourCompatibility.swift, TimelineFormat, ThumbnailService.swift, import orchestration in the view model",
      tests: "ProjectMediaTests.swift + ColourCompatibilityTests.swift + generated incompatible/shape/rate fixtures"
    },
    release: {
      primary: "VERSION, CHANGELOG.md, RELEASING.md, scripts/, .github/workflows/",
      supporting: "ApplicationBuildInfo.swift and ReleaseCompatibilityTests.swift",
      tests: "Strict CI, app-bundle verification, DMG/ZIP checksums, draft download and manual smoke test"
    }
  };

  const searchIndex = [
    ["Architecture and targets", "FrogmouthApp, FrogmouthCore, benchmark, dependencies", "structure"],
    ["Project structure", "Package.swift Sources Tests scripts workflows docs", "structure"],
    ["Import pipeline", "media asset fingerprint inspect compatibility append", "runtime"],
    ["Split operation", "playhead command two clips no temporary media", "runtime"],
    ["Trim operation", "drag transaction pending range commit autosave", "runtime"],
    ["Fade operation", "milliseconds opacity ramp FFmpeg video only", "runtime"],
    ["Temporary and cache files", "workspace partial manifest atomic save source untouched", "runtime"],
    ["Preview and playback", "AVFoundation composition AVPlayer segment map", "runtime"],
    ["Stabilization", "vidstab cache transform proxy stale effect", "runtime"],
    ["Export pipeline", "render plan filter graph validation atomic finalizer", "media"],
    ["Project schema", "ProjectState schema 2 JSON migration Codable", "domain"],
    ["Undo and redo", "ProjectCommand ProjectEditor ProjectHistory snapshots", "domain"],
    ["Exact time", "MediaTime range FrameRate rational frames CoreMedia", "domain"],
    ["SwiftUI and AppKit", "view model representable panels window keyboard", "ui"],
    ["Concurrency", "MainActor actors Sendable cancellation generation", "swift"],
    ["Swift libraries", "AVFoundation CryptoKit ImageIO UniformTypeIdentifiers", "swift"],
    ["Testing patterns", "Swift Testing @Test #expect fixtures fakes integration", "tests"],
    ["Configuration", "environment variables VERSION Package.swift CI", "config"],
    ["Release process", "tag DMG ZIP checksums draft GitHub", "config"],
    ["Where to change code", "AI review invariants developer playbook", "contribute"],
    ["ProjectDocumentViewModel.swift", "main actor coordinator hotspot", "ui"],
    ["TimelineEditing.swift", "commands validation history trim", "domain"],
    ["TimelineRenderTests.swift", "FFmpeg argv real media audio luma", "tests"],
    ["ProjectPersistence.swift", "actor document session autosave atomic write", "domain"]
  ];

  function showChapter(index, options = {}) {
    activeIndex = Math.min(Math.max(index, 0), chapters.length - 1);
    chapters.forEach((chapter, chapterIndex) => chapter.classList.toggle("is-active", chapterIndex === activeIndex));
    navButtons.forEach((button, buttonIndex) => {
      const active = buttonIndex === activeIndex;
      button.classList.toggle("is-active", active);
      if (active) button.setAttribute("aria-current", "page");
      else button.removeAttribute("aria-current");
    });

    const chapter = chapters[activeIndex];
    const humanIndex = activeIndex + 1;
    const percent = Math.round((humanIndex / chapters.length) * 100);
    title.textContent = chapter.dataset.title;
    progressLabel.textContent = `Chapter ${humanIndex} of ${chapters.length}`;
    progressPercent.textContent = `${percent}%`;
    progressBar.style.width = `${percent}%`;
    chapterPosition.textContent = `${String(humanIndex).padStart(2, "0")} / ${String(chapters.length).padStart(2, "0")}`;
    previousButton.disabled = activeIndex === 0;
    nextButton.disabled = activeIndex === chapters.length - 1;
    history.replaceState(null, "", `#${chapter.id}`);
    document.title = `${chapter.dataset.title} · Frogmouth Codebase Field Guide`;
    if (options.scroll !== false) window.scrollTo({ top: 0, behavior: options.instant ? "auto" : "smooth" });
    if (options.focus) document.querySelector("#chapter-stage").focus({ preventScroll: true });
  }

  function renderArchitecture(key) {
    const detail = architectureDetails[key];
    document.querySelectorAll("[data-node]").forEach((node) => node.classList.toggle("is-selected", node.dataset.node === key));
    document.querySelector("#architecture-detail").innerHTML = `
      <span class="detail-type">${detail.type}</span>
      <h2>${detail.title}</h2>
      <p>${detail.body}</p>
      <ul>${detail.bullets.map((bullet) => `<li>${bullet}</li>`).join("")}</ul>
      <a href="../../${detail.path}">${detail.path} →</a>
    `;
  }

  function renderFlow(key) {
    const flow = flows[key];
    document.querySelectorAll("[data-flow]").forEach((button) => {
      button.setAttribute("aria-selected", button.dataset.flow === key ? "true" : "false");
    });
    document.querySelector("#flow-summary").textContent = flow.summary;
    document.querySelector("#flow-stage").innerHTML = flow.steps.map((step, index) => `
      <article class="flow-step">
        <span class="flow-step-index">0${index + 1}</span>
        <h2>${step[0]}</h2>
        <p>${step[1]}</p>
        <code>${step[2]}</code>
      </article>
    `).join("");
  }

  function renderOperation(key) {
    const operation = operations[key];
    document.querySelectorAll("[data-operation]").forEach((button) => {
      button.setAttribute("aria-selected", button.dataset.operation === key ? "true" : "false");
    });
    document.querySelector("#operation-stage").innerHTML = `
      <div class="operation-title-row">
        <div><h3>${operation.title}</h3><p>${operation.summary}</p></div>
        <span class="operation-cost ${operation.heavy ? "heavy" : ""}">${operation.cost}</span>
      </div>
      <div class="operation-diagram">
        ${operation.layers.map((layer) => `
          <article class="operation-layer">
            <span>${layer[0]}</span>
            <h4>${layer[1]}</h4>
            <p>${layer[2]}</p>
            <code>${layer[3]}</code>
          </article>
        `).join("")}
      </div>
      <div class="file-ledger">
        ${operation.files.map((file) => `
          <article class="${file[0]}">
            <span>${file[0]}</span>
            <strong>${file[1]}</strong>
            <small>${file[2]}</small>
          </article>
        `).join("")}
      </div>
    `;
  }

  function renderRoute(key) {
    const route = routes[key];
    document.querySelector("#router-result").innerHTML = `
      <article><span>Start here</span><p><code>${route.primary}</code></p></article>
      <article><span>Then inspect</span><p>${route.supporting}</p></article>
      <article><span>Evidence expected</span><p>${route.tests}</p></article>
    `;
  }

  function showToast(message) {
    clearTimeout(toastTimer);
    toast.textContent = message;
    toast.classList.add("is-visible");
    toastTimer = setTimeout(() => toast.classList.remove("is-visible"), 1800);
  }

  async function copyText(text) {
    try {
      await navigator.clipboard.writeText(text);
    } catch {
      const input = document.createElement("textarea");
      input.value = text;
      document.body.append(input);
      input.select();
      document.execCommand("copy");
      input.remove();
    }
    showToast(`Copied: ${text}`);
  }

  function renderSearch(query = "") {
    const normalized = query.trim().toLowerCase();
    const matches = searchIndex.filter((item) => !normalized || `${item[0]} ${item[1]}`.toLowerCase().includes(normalized));
    document.querySelector("#search-results").innerHTML = matches.length
      ? matches.map((item) => `
          <button class="search-result" data-search-target="${item[2]}">
            <strong>${item[0]}</strong>
            <small>${item[1]}</small>
          </button>
        `).join("")
      : `<div class="empty-results">No match. Try a subsystem, source filename, or behavior.</div>`;
  }

  navButtons.forEach((button, index) => button.addEventListener("click", () => showChapter(index)));
  previousButton.addEventListener("click", () => showChapter(activeIndex - 1, { focus: true }));
  nextButton.addEventListener("click", () => showChapter(activeIndex + 1, { focus: true }));
  document.querySelectorAll("[data-jump]").forEach((button) => button.addEventListener("click", () => {
    const index = chapters.findIndex((chapter) => chapter.id === button.dataset.jump);
    showChapter(index, { focus: true });
  }));

  document.querySelectorAll("[data-node]").forEach((button) => button.addEventListener("click", () => renderArchitecture(button.dataset.node)));
  document.querySelectorAll("[data-flow]").forEach((button) => button.addEventListener("click", () => renderFlow(button.dataset.flow)));
  document.querySelectorAll("[data-operation]").forEach((button) => button.addEventListener("click", () => renderOperation(button.dataset.operation)));
  document.querySelectorAll("[data-copy]").forEach((button) => button.addEventListener("click", () => copyText(button.dataset.copy)));

  document.querySelectorAll("[data-test-filter]").forEach((button) => button.addEventListener("click", () => {
    const filter = button.dataset.testFilter;
    document.querySelectorAll("[data-test-filter]").forEach((candidate) => candidate.classList.toggle("is-active", candidate === button));
    document.querySelectorAll("[data-test-type]").forEach((card) => {
      card.classList.toggle("is-hidden", filter !== "all" && card.dataset.testType !== filter);
    });
  }));

  const changeSelect = document.querySelector("#change-select");
  changeSelect.addEventListener("change", () => renderRoute(changeSelect.value));

  const searchDialog = document.querySelector("#search-dialog");
  const keyboardDialog = document.querySelector("#keyboard-dialog");
  const searchInput = document.querySelector("#search-input");
  document.querySelector("#search-button").addEventListener("click", () => {
    renderSearch();
    searchDialog.showModal();
    searchInput.focus();
  });
  document.querySelector("#keyboard-help-button").addEventListener("click", () => keyboardDialog.showModal());
  document.querySelectorAll("[data-close-dialog]").forEach((button) => button.addEventListener("click", () => button.closest("dialog").close()));
  searchInput.addEventListener("input", () => renderSearch(searchInput.value));
  document.querySelector("#search-results").addEventListener("click", (event) => {
    const target = event.target.closest("[data-search-target]");
    if (!target) return;
    searchDialog.close();
    const index = chapters.findIndex((chapter) => chapter.id === target.dataset.searchTarget);
    showChapter(index, { focus: true });
  });

  const themeButton = document.querySelector("#theme-button");
  const themeIcon = document.querySelector("#theme-icon");
  const savedTheme = localStorage.getItem("frogmouth-guide-theme");
  if (savedTheme === "light") {
    document.documentElement.dataset.theme = "light";
    themeIcon.textContent = "☾";
  }
  themeButton.addEventListener("click", () => {
    const nextTheme = document.documentElement.dataset.theme === "dark" ? "light" : "dark";
    document.documentElement.dataset.theme = nextTheme;
    themeIcon.textContent = nextTheme === "dark" ? "☼" : "☾";
    localStorage.setItem("frogmouth-guide-theme", nextTheme);
  });

  document.addEventListener("keydown", (event) => {
    const interactive = ["INPUT", "SELECT", "TEXTAREA"].includes(document.activeElement?.tagName);
    if (event.key === "/" && !interactive) {
      event.preventDefault();
      renderSearch();
      searchDialog.showModal();
      searchInput.focus();
      return;
    }
    if (event.key === "?" && !interactive) {
      keyboardDialog.showModal();
      return;
    }
    if (interactive || document.querySelector("dialog[open]")) return;
    if (event.key === "ArrowRight") showChapter(activeIndex + 1, { focus: true });
    if (event.key === "ArrowLeft") showChapter(activeIndex - 1, { focus: true });
    if (event.key === "Home") showChapter(0, { focus: true });
    if (event.key === "End") showChapter(chapters.length - 1, { focus: true });
  });

  window.addEventListener("hashchange", () => {
    const index = chapters.findIndex((chapter) => chapter.id === location.hash.slice(1));
    if (index >= 0 && index !== activeIndex) showChapter(index, { scroll: false });
  });

  renderArchitecture("app");
  renderFlow("startup");
  renderOperation("split");
  renderRoute(changeSelect.value);
  renderSearch();
  showChapter(activeIndex, { scroll: false });
})();

// fog-of-war-boards: the broadcast chrome, inherited from cogame-babel.
//
// PROVENANCE. Everything between the BEGIN/END markers below is copied
// BYTE-FOR-BYTE out of `client/renderer.js` of Metta-AI/cogame-babel at
// commit d55d999, as the contiguous line regions the design note names:
// 101-124, 680-733, 735-744, 790-863, 963-970, 972-1027, 1029-1048 and
// 1142-1222. Exactly SIX copied lines/regions are edited, each marked
// `EDIT n` right where it is, and everything else in this file is either
// those copied bytes or appended at the very end. Nothing is renamed in
// place. tools/ci/chrome_scope_check.mjs fails the build if the markers
// go missing, so a future tidy-up cannot quietly rewrite the chrome.
//
// The game's own drawing lives in client/renderer.js and declares NO
// identifier this file exports (a game-block `function markBeat` is
// hoisted over a chrome alias and silently turns every scrub beat into an
// unlabelled div that never seeks -- tandem, 2026-08-23).
(function () {
  "use strict";

  // Carried with the chrome because the copied regions call them:
  // babel's palette (renderer.js 23-31) and seat colour (85-87). They stay
  // PRIVATE to this file -- the game block draws with its own palette, and
  // the scope check forbids it from re-declaring anything exported here.

  var COLORS = ["red", "blue", "green", "yellow", "violet", "orange"];
  var COLOR_HEX = {
    red: "#e0523a",
    blue: "#3f7cc4",
    green: "#45a85e",
    yellow: "#ddc531",
    violet: "#a86fd6",
    orange: "#e08a3a"
  };

  function seatColor(index) {
    return COLORS[index % COLORS.length];
  }

  // ---- BEGIN copied cogame-babel renderer.js 101-124 ----
  function ellipsize(ctx, text, maxWidth) {
    if (ctx.measureText(text).width <= maxWidth) return text;
    var cut = text;
    while (cut.length > 1 && ctx.measureText(cut + "…").width > maxWidth) {
      cut = cut.slice(0, -1);
    }
    return cut + "…";
  }

  // Colour helpers for the shape rims / highlights.
  function hexToRgb(hex) {
    var n = parseInt(hex.slice(1), 16);
    return [(n >> 16) & 255, (n >> 8) & 255, n & 255];
  }
  function shade(hex, factor) {
    var c = hexToRgb(hex).map(function (v) {
      return Math.max(0, Math.min(255, Math.round(v * factor)));
    });
    return "rgb(" + c[0] + "," + c[1] + "," + c[2] + ")";
  }
  function rgba(hex, alpha) {
    var c = hexToRgb(hex);
    return "rgba(" + c[0] + "," + c[1] + "," + c[2] + "," + alpha + ")";
  }
  // ---- END copied cogame-babel renderer.js 101-124 ----

  // ---- BEGIN copied cogame-babel renderer.js 680-733 ----
  // ---- Names ---------------------------------------------------------------

  // The agents only ever hear anonymous table names ("Sprocket", "Gizmo");
  // the payload carries the policy names separately, spectator-side only.
  // A name map swaps them in wherever a name is RENDERED while the
  // underlying events keep the aliases. Baseline fillers keep their alias.
  // The map also carries the canonical alphabet so feed lines can spell
  // messages the way the stage does.
  function isBaselineFiller(name) {
    return /^baseline(\s*\(\d+\))?$/i.test(name);
  }

  function makeNameMap(tableNames, policyNames, glyphs) {
    var table = tableNames || [];
    var alphabet = glyphs || [];
    var display = table.map(function (name, i) {
      var policy = policyNames && policyNames[i];
      return (policy && !isBaselineFiller(policy)) ? policy : name;
    });
    var byAlias = {};
    table.forEach(function (name, i) {
      if (name && display[i] && display[i] !== name) byAlias[name] = display[i];
    });
    var aliases = Object.keys(byAlias);
    var pattern = aliases.length ? new RegExp(
      "\\b(?:" + aliases.map(function (name) {
        return name.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
      }).join("|") + ")\\b", "g") : null;
    return {
      seat: function (i) { return display[i] || ("Seat " + i); },
      text: function (text) {
        if (!pattern) return text;
        return text.replace(pattern, function (match) {
          return byAlias[match];
        });
      },
      glyph: function (t) {
        return alphabet[t] !== undefined ? alphabet[t] : "?";
      }
    };
  }

  function applyNames(seats, nameMap) {
    return (seats || []).map(function (seat, i) {
      var copy = Object.assign({}, seat);
      copy.name = nameMap.seat(i);
      return copy;
    });
  }

  function clampName(name) {
    var n = name || "";
    return n.length > 24 ? n.slice(0, 23) + "…" : n;
  }
  // ---- END copied cogame-babel renderer.js 680-733 ----

  // ---- BEGIN copied cogame-babel renderer.js 735-744 ----
  // ---- Event feed ----------------------------------------------------------

  // Round numbers in events are 0-based per the sim; a payload that counts
  // from 1 is tolerated by reading the first round event.
  function roundBase(events) {
    for (var i = 0; i < events.length; i++) {
      if (events[i].kind === "round") return events[i].round === 1 ? 1 : 0;
    }
    return 0;
  }
  // ---- END copied cogame-babel renderer.js 735-744 ----

  // ---- BEGIN copied cogame-babel renderer.js 790-863 ----
  function blockHead(block) {
    // EDIT 1 (starter line 791): a block is one PLY, not a round.
    return block < 0 ? "SETUP" : "PLY " + (block + 1);
  }

  // Renders the full transcript grouped into one section per round.
  // currentIndex (replay) marks how far playback has reached; omit it for
  // live views.
  function renderFeed(element, events, nameMap, currentIndex) {
    var live = currentIndex === undefined;
    var limit = live ? events.length : currentIndex;
    var base = roundBase(events);
    var html = "";
    var lastBlock = null;
    var ctx = { pairs: null, successes: 0, pairRounds: 0 };
    var lastNotes = {};
    for (var i = 0; i < events.length; i++) {
      var event = events[i];
      var block = event.kind === "start" ? -1 :
        event.kind === "end" ? lastBlock : event.round - base;
      if (block !== lastBlock) {
        html += '<div class="feed-round-head">' + blockHead(block) +
          "</div>";
        lastBlock = block;
      }
      if (event.kind === "round") ctx.pairs = event.pairs || [];
      if (event.kind === "pick") {
        ctx.pairRounds += 1;
        if (event.correct) ctx.successes += 1;
      }
      var scored = event.kind === "pick" && event.correct;
      var cls = "feed-line feed-" + event.kind +
        (event.kind === "speak" ? " seat" + (event.seat % COLORS.length) :
          "") +
        (event.kind === "end" ? " feed-rwin" : "") +
        (scored ? " feed-score seat" + (event.seat % COLORS.length) : "") +
        (i >= limit ? " feed-future" : "");
      html += '<div class="' + cls + '">' +
        // EDIT 2 (starter line 827): the line text is injected by
        // FogChrome.setFeedText(fn) instead of a chrome-local
        // describeEvent.
        escapeHtml(feedText(event, nameMap, ctx)) + "</div>";
      // EDIT 3 (starter lines 829-836): the speak/pick notes sub-line
      // becomes the attempt sub-line, carrying the mover's quoted `say`.
      if (event.kind === "attempt" && event.say &&
          event.say !== lastNotes[event.seat]) {
        lastNotes[event.seat] = event.say;
        html += '<div class="feed-line feed-say' +
          (i >= limit ? " feed-future" : "") + '">' +
          escapeHtml(clampName(nameMap.seat(event.seat)) + ": \u201c" +
            nameMap.text(event.say) + "\u201d") + "</div>";
      }
    }
    element.innerHTML = html;

    if (live || limit >= events.length) {
      element.scrollTop = element.scrollHeight;
      return;
    }
    // Keep the playhead's neighbourhood in view while scrubbing.
    var lines = element.querySelectorAll(".feed-line");
    var target = null;
    for (var l = 0; l < lines.length; l++) {
      if (!lines[l].classList.contains("feed-future")) target = lines[l];
    }
    if (target && element.dataset.anchor !== String(limit)) {
      element.dataset.anchor = String(limit);
      element.scrollTo({
        top: Math.max(target.offsetTop - element.offsetTop -
          element.clientHeight * 0.6, 0)
      });
    }
  }

  function escapeHtml(text) {
    return text.replace(/[&<>"]/g, function (c) {
      return { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c];
    });
  }
  // ---- END copied cogame-babel renderer.js 790-863 ----

  // ---- BEGIN copied cogame-babel renderer.js 963-970 ----
  function reasonLine(results) {
    switch (results.reason) {
      case "deadline":
        // EDIT 6 (starter lines 966-967): plies, not rounds.
        return "episode deadline: scored on " + (results.plies || 0) +
          " of " + (results.maxPlies || results.plies || 0) + " plies";
      default: return "";
    }
  }
  // ---- END copied cogame-babel renderer.js 963-970 ----

  // ---- BEGIN copied cogame-babel renderer.js 972-1027 ----
  // Final standings overlay: verdict up top, ranked rows below.
  function updateEndscreen(container, results, show, nameMap) {
    if (!container) return;
    container.classList.toggle("show", !!show);
    if (!show || !results || container.dataset.built === "yes") return;
    container.dataset.built = "yes";
    var names = (results.names || []).map(function (name, i) {
      return nameMap ? nameMap.seat(i) : name;
    });
    var scores = results.scores || [];
    var correct = results.correct || [];
    var order = names.map(function (_, i) { return i; });
    order.sort(function (a, b) {
      var byScore = (scores[b] || 0) - (scores[a] || 0);
      if (byScore) return byScore;
      return (correct[b] || 0) - (correct[a] || 0);
    });
    var topIndex = order.length ? order[0] : -1;
    var level = order.every(function (i) {
      return (scores[i] || 0) === (scores[topIndex] || 0);
    });
    var verdictColor = !level && topIndex >= 0 ? seatColor(topIndex) : "";
    var verdict = !level && topIndex >= 0 ?
      escapeHtml(names[topIndex]) + " LEADS THE TABLE" : "ALL LEVEL";
    var reason = reasonLine(results);
    var columns = endColumns(results);          // EDIT 5c: injected columns
    var html = '<div class="end-panel">' +
      '<div class="end-title">FINAL — ' + (results.rounds || 0) + " ROUND" +
      ((results.rounds || 0) === 1 ? "" : "S") + "</div>" +
      '<div class="end-verdict ' + verdictColor + '">' + verdict + "</div>" +
      (reason ? '<div class="end-reason">' + escapeHtml(reason) + "</div>" :
        "") +
      '<div class="end-rows">' +
      '<span class="end-head"></span><span class="end-head"></span>' +
      // EDIT 5a (starter lines 1005-1008): the four hard-coded column
      // heads become the injected endColumns(results).heads.
      columns.heads.map(function (head) {
        return '<span class="end-head">' + escapeHtml(head) + "</span>";
      }).join("");
    order.forEach(function (i, rank) {
      var leader = !level && i === topIndex;
      var cell = function (value) {
        return '<span class="end-cell' + (leader ? " end-row-winner" : "") +
          '">' + value + "</span>";
      };
      html += '<span class="end-cell rank' +
        (leader ? " end-row-winner" : "") + '">' + (rank + 1) + "</span>" +
        '<span class="end-cell name ' + seatColor(i) +
        (leader ? " end-row-winner" : "") + '">' + escapeHtml(names[i]) +
        "</span>" +
        // EDIT 5b (starter lines 1020-1023): the four hard-coded cells
        // become the injected endColumns(results).cell(i).
        columns.cell(i).map(cell).join("");
    });
    html += "</div></div>";
    container.innerHTML = html;
  }
  // ---- END copied cogame-babel renderer.js 972-1027 ----

  // ---- BEGIN copied cogame-babel renderer.js 1029-1048 ----
  function bindFeedToggle(button, startCollapsed) {
    if (!button) return;
    if (startCollapsed) {
      document.body.classList.add("feed-collapsed");
      requestAnimationFrame(function () {
        window.dispatchEvent(new Event("resize"));
      });
    }
    function refresh() {
      button.textContent =
        document.body.classList.contains("feed-collapsed") ?
          "« LOG" : "LOG »";
    }
    button.onclick = function () {
      document.body.classList.toggle("feed-collapsed");
      refresh();
      window.dispatchEvent(new Event("resize"));
    };
    refresh();
  }
  // ---- END copied cogame-babel renderer.js 1029-1048 ----

  // ---- BEGIN copied cogame-babel renderer.js 1142-1222 ----
  // Scrubber: a click/drag-to-seek track with one span per round, a marker
  // per pick (coloured by the listener on success, a neutral ghost on
  // failure) and the end (taller).
  function buildScrub(container, events, onSeek) {
    container.innerHTML = "";
    var track = document.createElement("div");
    track.className = "scrub-track";
    container.appendChild(track);
    var fill = document.createElement("div");
    fill.className = "scrub-fill";
    container.appendChild(fill);
    var base = roundBase(events);
    var blockStarts = [];
    var lastBlock = null;
    events.forEach(function (event, i) {
      var block = event.kind === "start" ? -1 :
        event.kind === "end" ? lastBlock : event.round - base;
      if (block !== lastBlock) {
        blockStarts.push(i);
        lastBlock = block;
      }
    });
    blockStarts.forEach(function (startIdx, r) {
      var endIdx = r + 1 < blockStarts.length ?
        blockStarts[r + 1] : events.length;
      var span = document.createElement("div");
      span.className = "round-span" + (r % 2 ? " alt" : "");
      span.style.left = (startIdx / events.length * 100) + "%";
      span.style.width = ((endIdx - startIdx) / events.length * 100) + "%";
      container.appendChild(span);
      if (r > 0) {
        var sep = document.createElement("div");
        sep.className = "round-sep";
        sep.style.left = (startIdx / events.length * 100) + "%";
        container.appendChild(sep);
      }
    });
    // EDIT 4 (starter lines 1179-1189): every recorded event gets a
    // labelled, clickable beat button; markPlyBeat is appended at the end
    // of this file.
    events.forEach(function (event, i) {
      markPlyBeat(container, event, i, events.length, onSeek);
    });
    var head = document.createElement("div");
    head.className = "scrub-head";
    container.appendChild(head);

    function seekFromEvent(evt) {
      var rect = container.getBoundingClientRect();
      if (!rect.width) return;   // hidden/unlaid-out page: nothing to seek
      var x = (evt.touches ? evt.touches[0].clientX : evt.clientX) -
        rect.left;
      var fraction = Math.max(0, Math.min(x / rect.width, 1));
      onSeek(Math.round(fraction * events.length));
    }
    var dragging = false;
    container.addEventListener("pointerdown", function (evt) {
      dragging = true;
      try { container.setPointerCapture(evt.pointerId); } catch (ignore) {}
      seekFromEvent(evt);
    });
    container.addEventListener("pointermove", function (evt) {
      if (dragging) seekFromEvent(evt);
    });
    container.addEventListener("pointerup", function () {
      dragging = false;
    });

    return {
      update: function (index) {
        var pct = events.length ? (index / events.length * 100) : 0;
        fill.style.width = pct + "%";
        head.style.left = pct + "%";
      }
    };
  }
  // ---- END copied cogame-babel renderer.js 1142-1222 ----

  // ==========================================================================
  // APPENDED for fog-of-war-boards. Nothing above this line is new; nothing
  // below it is copied. In the order the design note pins: relayout(),
  // markPlyBeat(), setFeedText(), setEndColumns(), the window.FogChrome
  // export.
  // ==========================================================================

  // --- relayout -------------------------------------------------------------
  // Measures #transport and publishes --band (its height) and --hudscale on
  // :root. #endscreen is `bottom: var(--band)`, so the endcard stops exactly
  // where the transport begins and the scrubber and play button are always
  // clickable. Runs on load, on resize, and therefore on every feed toggle:
  // bindFeedToggle dispatches a resize.
  function relayout() {
    var root = document.documentElement;
    var transport = document.getElementById("transport");
    var band = 0;
    if (transport) {
      var box = transport.getBoundingClientRect();
      band = Math.round(box.height);
    }
    root.style.setProperty("--band", band + "px");
    var width = window.innerWidth || root.clientWidth || 1280;
    var scale = Math.max(0.72, Math.min(width / 1280, 1));
    root.style.setProperty("--hudscale", String(Math.round(scale * 100) / 100));
  }
  window.addEventListener("load", relayout);
  window.addEventListener("resize", relayout);

  // --- markPlyBeat ----------------------------------------------------------
  // One labelled, clickable button per recorded event. It lives in the chrome
  // and NOT in the game block on purpose: a game-block `function markBeat`
  // would be hoisted over a chrome alias and silently turn every beat into an
  // unlabelled div that never seeks (tandem, 2026-08-23).
  function beatLabel(event, index) {
    var ply = typeof event.round === "number" && event.round >= 0 ?
      "ply " + (event.round + 1) : "setup";
    switch (event.kind) {
      case "start": return "setup";
      case "sense": return ply + " \u2014 senses " + (event.anchor || "?");
      case "attempt":
        return ply + " \u2014 plays " + (event.cell || "?") + " (" +
          (event.result || "?") + ")";
      case "win":
        return ply + " \u2014 " + (event.how === "line" ? "line" : "connection");
      case "end":
        return "end \u2014 " + (event.reason || "") +
          (event.ending ? " / " + event.ending : "");
      default: return ply + " \u2014 " + event.kind;
    }
  }

  function markPlyBeat(container, event, index, total, onSeek) {
    var button = document.createElement("button");
    button.type = "button";
    var seat = typeof event.seat === "number" && event.seat >= 0 ?
      " seat" + (event.seat % 2) : "";
    var occupied = event.kind === "attempt" && event.result === "occupied" ?
      " occupied" : "";
    button.className = "beat-marker beat-" + event.kind + seat + occupied;
    var label = beatLabel(event, index);
    button.setAttribute("aria-label", label);
    button.title = label;
    button.style.left = ((index + 1) / Math.max(total, 1) * 100) + "%";
    button.addEventListener("click", function (evt) {
      evt.stopPropagation();
      if (typeof onSeek === "function") onSeek(index + 1);
    });
    container.appendChild(button);
  }

  // --- setFeedText ----------------------------------------------------------
  // The game block owns every human-facing sentence; the chrome owns the
  // grouping, the scrolling and the escaping.
  var feedText = function (event) {
    return String(event && event.kind || "");
  };

  function setFeedText(fn) {
    if (typeof fn === "function") feedText = fn;
  }

  // --- setEndColumns --------------------------------------------------------
  // The endcard's columns are this game's, not babel's: score, stones,
  // probes, discovered, guess accuracy.
  var endColumns = function () {
    return { heads: [], cell: function () { return []; } };
  };

  function setEndColumns(fn) {
    if (typeof fn === "function") endColumns = fn;
  }

  window.FogChrome = {
    ellipsize: ellipsize,
    hexToRgb: hexToRgb,
    shade: shade,
    rgba: rgba,
    isBaselineFiller: isBaselineFiller,
    makeNameMap: makeNameMap,
    applyNames: applyNames,
    clampName: clampName,
    roundBase: roundBase,
    blockHead: blockHead,
    renderFeed: renderFeed,
    escapeHtml: escapeHtml,
    reasonLine: reasonLine,
    updateEndscreen: updateEndscreen,
    bindFeedToggle: bindFeedToggle,
    buildScrub: buildScrub,
    relayout: relayout,
    markPlyBeat: markPlyBeat,
    setFeedText: setFeedText,
    setEndColumns: setEndColumns
  };
})();

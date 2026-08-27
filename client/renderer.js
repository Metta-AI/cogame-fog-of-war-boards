// fog-of-war-boards: the game block.
//
// The chrome (feed grouping, names, endcard shell, scrubber, transport)
// is inherited verbatim from cogame-babel and lives in chrome_common.js;
// this file only draws THIS game and feeds the chrome its sentences. It
// declares no identifier that FogChrome exports -- tools/ci/chrome_scope_check.mjs
// fails the build if it ever does (tandem, 2026-08-23).
//
// One canvas, three viewports: the TRUE board in the middle and each
// seat's BELIEF board beside it. The gap between them is the show.
//
// It draws state objects shaped exactly like the sim's boardStateJson:
//   {mode, size, abrupt, sense, board:["empty"|"seat0"|"seat1", ...],
//    seats:[{name, policy, stones, probes, discovered, distToWin, score,
//            known:[cell], sensedEmpty:[{cell,ply}], guess:[cell], say,
//            notes, scripted, fellBack} x2],
//    mover, ply, maxPlies, plies, lastAttempt, lastSense, winner,
//    winPath, phase, gameDone, reason, ending}
(function () {
  "use strict";

  var C = window.FogChrome;

  // Ink & Print palette, matching the inherited broadcast chrome.
  var SEAT_HEX = ["#e0523a", "#3f7cc4"];
  var SEAT_CLASS = ["seat0", "seat1"];
  var PAPER = "#f2e8d8";
  var INK = "#2a1f16";
  var AMBER = "#e8a33d";
  var GHOST = "#8a7f72";
  var BOARD_FONT = "'rajdhani', system-ui, sans-serif";

  // The server caps `say` at 80 runes; the scorebug reserves a band sized
  // from that cap so a full-length line can never be laid out where there
  // is no room for it (cogchemists, 2026-08-24).
  var MAX_SAY_LEN = 80;

  // Transient effects, in ms.
  var FLASH_MS = 900;          // a discovery flashes on all three boards
  var SENSE_HOLD_MS = 700;     // the reconnaissance window holds
  var WIN_GLOW_MS = 1600;

  // Replay pacing, in ms, keyed by the kind of the event on screen. The
  // smoke replay is a scripted dark-hex-5 episode -- two `probe` seats
  // finish it in nine plies, so twelve events -- and the wasm-viewer soak
  // watches for 10 s of UNINTERRUPTED advance. These dwells are what keep
  // that replay playing for ~15 s; tests/test_bot.nim reads them straight
  // out of this file and checks the arithmetic, so shortening one fails
  // the build rather than the soak.
  var DWELL = {start: 900, sense: 900, placed: 1000, occupied: 1500,
    win: 2200, end: 2200, other: 600};

  var ASSETS = ["arena_floor.png", "soldier_red_front.png",
    "soldier_blue_front.png", "fog_hatch.png", "lens.png"];

  // The feed rebuilds the board as it walks the events, and the events
  // carry algebraic names rather than a board size, so the drivers publish
  // the episode's shape here before the first renderFeed call.
  var feedSize = 5;
  var feedSense = 0;

  // ---- Coordinates ---------------------------------------------------------

  function cellOf(size, name) {
    if (typeof name !== "string" || name.length < 2) return -1;
    var col = name.charCodeAt(0) - 97;
    var row = parseInt(name.slice(1), 10) - 1;
    if (isNaN(row) || col < 0 || col >= size || row < 0 || row >= size) {
      return -1;
    }
    return row * size + col;
  }

  function nameOf(size, cell) {
    return String.fromCharCode(97 + (cell % size)) +
      (Math.floor(cell / size) + 1);
  }

  function cellSet(size, names) {
    var set = {};
    (names || []).forEach(function (name) {
      var cell = cellOf(size, name);
      if (cell >= 0) set[cell] = true;
    });
    return set;
  }

  // ---- Assets --------------------------------------------------------------

  function assetUrl(base, name) {
    return String(base || ".").replace(/\/$/, "") + "/" + name;
  }

  function loadAssets(base, done) {
    var images = {};
    var pending = ASSETS.length;
    ASSETS.forEach(function (name) {
      var img = new Image();
      img.onload = img.onerror = function () {
        pending -= 1;
        if (pending === 0) done(images);
      };
      img.src = assetUrl(base, name);
      images[name] = img;
    });
  }

  // ---- Geometry ------------------------------------------------------------

  // Pointy-top hexes on axial coordinates (q = file, r = rank). The six
  // neighbours of the sim -- (r, c+-1), (r+-1, c), (r-1, c+1), (r+1, c-1)
  // -- are exactly the six axial neighbours, so the picture and the rules
  // are the same relation.
  var SQRT3 = Math.sqrt(3);

  function boardUnits(size, mode) {
    if (mode === "phantom-ttt") {
      return { w: size, h: size };
    }
    return { w: SQRT3 * (1.5 * (size - 1) + 1), h: 1.5 * (size - 1) + 2 };
  }

  function hexCentre(size, cell, radius, originX, originY) {
    var row = Math.floor(cell / size);
    var col = cell % size;
    return {
      x: originX + radius * SQRT3 * (col + row / 2) + radius * SQRT3 / 2,
      y: originY + radius * 1.5 * (size - 1 - row) + radius
    };
  }

  function squareCentre(size, cell, side, originX, originY) {
    var row = Math.floor(cell / size);
    var col = cell % size;
    return {
      x: originX + (col + 0.5) * side,
      y: originY + (size - 1 - row + 0.5) * side
    };
  }

  function fitBoard(box, size, mode) {
    // Solves the largest board that fits the box, and centres it.
    var units = boardUnits(size, mode);
    if (mode === "phantom-ttt") {
      var side = Math.min(box.w / units.w, box.h / units.h);
      return {
        mode: mode, size: size, side: side,
        w: side * units.w, h: side * units.h,
        x: box.x + (box.w - side * units.w) / 2,
        y: box.y + (box.h - side * units.h) / 2
      };
    }
    var radius = Math.min(box.w / units.w, box.h / units.h);
    return {
      mode: mode, size: size, radius: radius,
      w: radius * units.w, h: radius * units.h,
      x: box.x + (box.w - radius * units.w) / 2,
      y: box.y + (box.h - radius * units.h) / 2
    };
  }

  function centreOf(fit, cell) {
    if (fit.mode === "phantom-ttt") {
      return squareCentre(fit.size, cell, fit.side, fit.x, fit.y);
    }
    return hexCentre(fit.size, cell, fit.radius, fit.x, fit.y);
  }

  function cellRadius(fit) {
    return fit.mode === "phantom-ttt" ? fit.side * 0.5 : fit.radius;
  }

  // Above 640 px: the truth board in the middle at full size, flanked by
  // the two belief boards at 55 %. At and below 640 px: the truth board on
  // top, the two belief boards side by side beneath it at 40 %. Every
  // shipped board is small and fixed, so it always fits -- which is why
  // there is no zoom bar and no minimap.
  function viewports(width, height, hudscale) {
    var margin = Math.max(6, 10 * hudscale);
    var caption = Math.max(11, 15 * hudscale);
    var gap = Math.max(6, 12 * hudscale);
    var narrow = width <= 640;
    var boxes = [];
    if (!narrow) {
      var unit = (width - 2 * margin - 2 * gap) / 2.1;
      var side = unit * 0.55;
      var top = margin + caption;
      var full = height - 2 * margin - caption;
      var x = margin;
      boxes.push({ x: x, y: top + (full - full * 0.55) / 2,
        w: side, h: full * 0.55, scale: 0.55, caption: caption });
      x += side + gap;
      boxes.push({ x: x, y: top, w: unit, h: full, scale: 1,
        caption: caption });
      x += unit + gap;
      boxes.push({ x: x, y: top + (full - full * 0.55) / 2,
        w: side, h: full * 0.55, scale: 0.55, caption: caption });
      return { truth: boxes[1], belief: [boxes[0], boxes[2]],
        narrow: false, margin: margin, caption: caption };
    }
    var half = (width - 2 * margin - gap) / 2;
    var usable = height - 2 * margin - 2 * caption - gap;
    var truthH = usable * 0.58;
    var beliefH = usable * 0.42;
    var truth = { x: margin, y: margin + caption, w: width - 2 * margin,
      h: truthH, scale: 1, caption: caption };
    var beliefTop = margin + caption + truthH + gap + caption;
    return {
      truth: truth,
      belief: [
        { x: margin, y: beliefTop, w: half, h: beliefH, scale: 0.4,
          caption: caption },
        { x: margin + half + gap, y: beliefTop, w: half, h: beliefH,
          scale: 0.4, caption: caption }
      ],
      narrow: true, margin: margin, caption: caption
    };
  }

  // ---- Board drawing -------------------------------------------------------

  function hexPath(ctx, centre, radius) {
    ctx.beginPath();
    for (var k = 0; k < 6; k++) {
      var angle = Math.PI / 180 * (60 * k - 30);
      var px = centre.x + radius * Math.cos(angle);
      var py = centre.y + radius * Math.sin(angle);
      if (k === 0) ctx.moveTo(px, py); else ctx.lineTo(px, py);
    }
    ctx.closePath();
  }

  function cellPath(ctx, fit, cell) {
    var centre = centreOf(fit, cell);
    if (fit.mode === "phantom-ttt") {
      var half = fit.side * 0.46;
      ctx.beginPath();
      ctx.rect(centre.x - half, centre.y - half, half * 2, half * 2);
      return centre;
    }
    hexPath(ctx, centre, fit.radius * 0.94);
    return centre;
  }

  function drawEdges(ctx, fit) {
    // Red owns the two slanted files, blue the bottom and top ranks. The
    // strips say which pair of sides each seat is trying to join without a
    // word of explanation.
    if (fit.mode === "phantom-ttt") return;
    var n = fit.size;
    var r = fit.radius;
    var pairs = [
      { seat: 0, from: 0, to: (n - 1) * n, out: { x: -1, y: 0 } },
      { seat: 0, from: n - 1, to: (n - 1) * n + n - 1, out: { x: 1, y: 0 } },
      { seat: 1, from: 0, to: n - 1, out: { x: 0, y: 1 } },
      { seat: 1, from: (n - 1) * n, to: (n - 1) * n + n - 1,
        out: { x: 0, y: -1 } }
    ];
    ctx.save();
    ctx.lineWidth = Math.max(2, r * 0.28);
    ctx.lineCap = "round";
    pairs.forEach(function (edge) {
      var a = centreOf(fit, edge.from);
      var b = centreOf(fit, edge.to);
      var push = r * 0.92;
      ctx.strokeStyle = C.rgba(SEAT_HEX[edge.seat], 0.85);
      ctx.beginPath();
      ctx.moveTo(a.x + edge.out.x * push, a.y + edge.out.y * push);
      ctx.lineTo(b.x + edge.out.x * push, b.y + edge.out.y * push);
      ctx.stroke();
    });
    ctx.restore();
  }

  function drawStone(ctx, fit, cell, seat, alpha) {
    var centre = centreOf(fit, cell);
    var radius = cellRadius(fit) * (fit.mode === "phantom-ttt" ? 0.62 : 0.66);
    ctx.save();
    ctx.globalAlpha = alpha === undefined ? 1 : alpha;
    if (fit.mode === "phantom-ttt") {
      // X and O, drawn rather than sprited so they stay crisp.
      ctx.lineWidth = Math.max(2, radius * 0.3);
      ctx.lineCap = "round";
      ctx.strokeStyle = SEAT_HEX[seat];
      ctx.beginPath();
      if (seat === 0) {
        ctx.moveTo(centre.x - radius, centre.y - radius);
        ctx.lineTo(centre.x + radius, centre.y + radius);
        ctx.moveTo(centre.x + radius, centre.y - radius);
        ctx.lineTo(centre.x - radius, centre.y + radius);
      } else {
        ctx.arc(centre.x, centre.y, radius, 0, Math.PI * 2);
      }
      ctx.stroke();
    } else {
      ctx.fillStyle = SEAT_HEX[seat];
      ctx.strokeStyle = C.shade(SEAT_HEX[seat], 0.55);
      ctx.lineWidth = Math.max(1, radius * 0.14);
      ctx.beginPath();
      ctx.arc(centre.x, centre.y, radius, 0, Math.PI * 2);
      ctx.fill();
      ctx.stroke();
      ctx.beginPath();
      ctx.arc(centre.x - radius * 0.28, centre.y - radius * 0.3,
        radius * 0.24, 0, Math.PI * 2);
      ctx.fillStyle = "rgba(242, 232, 216, 0.32)";
      ctx.fill();
    }
    ctx.restore();
  }

  function drawRing(ctx, fit, cell, colour, dashed, width) {
    var centre = centreOf(fit, cell);
    var radius = cellRadius(fit) * 0.78;
    ctx.save();
    ctx.strokeStyle = colour;
    ctx.lineWidth = width || Math.max(1.5, radius * 0.14);
    if (dashed) ctx.setLineDash([radius * 0.4, radius * 0.32]);
    ctx.beginPath();
    ctx.arc(centre.x, centre.y, radius, 0, Math.PI * 2);
    ctx.stroke();
    ctx.restore();
  }

  function drawPath(ctx, fit, cells, alpha) {
    if (!cells || cells.length < 2) return;
    ctx.save();
    ctx.globalAlpha = alpha === undefined ? 1 : alpha;
    ctx.strokeStyle = AMBER;
    ctx.lineWidth = Math.max(2, cellRadius(fit) * 0.3);
    ctx.lineJoin = "round";
    ctx.lineCap = "round";
    ctx.beginPath();
    cells.forEach(function (cell, index) {
      var centre = centreOf(fit, cell);
      if (index === 0) ctx.moveTo(centre.x, centre.y);
      else ctx.lineTo(centre.x, centre.y);
    });
    ctx.stroke();
    ctx.restore();
  }

  function drawGrid(ctx, fit, tint) {
    ctx.save();
    for (var cell = 0; cell < fit.size * fit.size; cell++) {
      cellPath(ctx, fit, cell);
      ctx.fillStyle = tint;
      ctx.fill();
      ctx.strokeStyle = "rgba(242, 232, 216, 0.22)";
      ctx.lineWidth = 1;
      ctx.stroke();
    }
    ctx.restore();
  }

  function drawCaption(ctx, box, text, colour, hudscale) {
    ctx.save();
    ctx.font = "700 " + Math.round(Math.max(9, 12 * hudscale)) + "px " +
      BOARD_FONT;
    ctx.textAlign = "center";
    ctx.textBaseline = "bottom";
    ctx.fillStyle = colour;
    var label = C.ellipsize(ctx, text, box.w);
    ctx.fillText(label, box.x + box.w / 2, box.y - Math.max(2, 3 * hudscale));
    ctx.restore();
  }

  function drawFileRanks(ctx, fit, hudscale) {
    // Every cell has a readable algebraic name: the files run under the
    // board, the ranks down its left side. "c3", never "12".
    var size = fit.size;
    var px = Math.max(8, cellRadius(fit) * 0.5);
    ctx.save();
    ctx.font = "600 " + Math.round(px) + "px " + BOARD_FONT;
    ctx.fillStyle = GHOST;
    ctx.textAlign = "center";
    ctx.textBaseline = "top";
    for (var col = 0; col < size; col++) {
      var bottom = centreOf(fit, col);
      ctx.fillText(String.fromCharCode(97 + col), bottom.x,
        bottom.y + cellRadius(fit) * 0.85);
    }
    ctx.textAlign = "right";
    ctx.textBaseline = "middle";
    for (var row = 0; row < size; row++) {
      var left = centreOf(fit, row * size);
      ctx.fillText(String(row + 1), left.x - cellRadius(fit) * 0.95, left.y);
    }
    ctx.restore();
  }

  function drawTruth(ctx, box, state, images, fx, now, hudscale) {
    var size = state.size;
    // Reserve a gutter for the file letters and rank digits so a label can
    // never be laid out past the edge of the canvas.
    var fit = fitBoard({ x: box.x + box.w * 0.06, y: box.y,
      w: box.w * 0.92, h: box.h * 0.9 }, size, state.mode);
    drawGrid(ctx, fit, "rgba(242, 232, 216, 0.07)");
    drawEdges(ctx, fit);
    var proven = cellSet(size,
      ((state.seats || [])[state.mover] || {}).known);
    var pattern = null;
    var hatch = images["fog_hatch.png"];
    if (hatch && hatch.width) {
      pattern = ctx.createPattern(hatch, "repeat");
    }
    (state.board || []).forEach(function (occupant, cell) {
      if (occupant === "empty") return;
      var seat = occupant === "seat0" ? 0 : 1;
      drawStone(ctx, fit, cell, seat, 1);
      // The fog on the truth board is literally what the seat to move
      // cannot see: its opponent's stones, until it has proven them.
      if (!state.gameDone && seat !== state.mover && !proven[cell]) {
        ctx.save();
        cellPath(ctx, fit, cell);
        ctx.fillStyle = pattern || "rgba(42, 31, 22, 0.62)";
        ctx.globalAlpha = pattern ? 0.85 : 1;
        ctx.fill();
        ctx.restore();
      }
    });
    if (state.winner >= 0 && (state.winPath || []).length) {
      var path = (state.winPath || []).map(function (name) {
        return cellOf(size, name);
      });
      var age = fx.winAt ? now - fx.winAt : WIN_GLOW_MS;
      drawPath(ctx, fit, path,
        age < WIN_GLOW_MS ? 0.55 + 0.45 * Math.abs(Math.sin(age / 160)) : 1);
    }
    if (fx.senseAt && now - fx.senseAt < SENSE_HOLD_MS && fx.senseAnchor) {
      drawSenseWindow(ctx, fit, state, fx, images, now);
    }
    if (fx.flashAt && now - fx.flashAt < FLASH_MS && fx.flashCell >= 0) {
      drawFlash(ctx, fit, fx.flashCell, now - fx.flashAt);
    }
    drawFileRanks(ctx, fit, hudscale);
    return fit;
  }

  function drawSenseWindow(ctx, fit, state, fx, images, now) {
    var size = state.size;
    var span = state.sense || 2;
    var anchor = cellOf(size, fx.senseAnchor);
    if (anchor < 0) return;
    var row = Math.floor(anchor / size);
    var col = anchor % size;
    var cells = [];
    for (var i = 0; i < span; i++) {
      for (var j = 0; j < span; j++) {
        var r = row + i;
        var c = col + j;
        if (r < size && c < size) cells.push(r * size + c);
      }
    }
    if (!cells.length) return;
    var minX = Infinity, minY = Infinity, maxX = -Infinity, maxY = -Infinity;
    cells.forEach(function (cell) {
      var centre = centreOf(fit, cell);
      var radius = cellRadius(fit);
      minX = Math.min(minX, centre.x - radius);
      maxX = Math.max(maxX, centre.x + radius);
      minY = Math.min(minY, centre.y - radius);
      maxY = Math.max(maxY, centre.y + radius);
    });
    var eased = Math.min(1, (now - fx.senseAt) / 180);
    ctx.save();
    ctx.globalAlpha = 0.35 + 0.65 * eased;
    ctx.strokeStyle = AMBER;
    ctx.lineWidth = Math.max(2, cellRadius(fit) * 0.16);
    ctx.setLineDash([cellRadius(fit) * 0.5, cellRadius(fit) * 0.3]);
    ctx.strokeRect(minX, minY, maxX - minX, maxY - minY);
    ctx.setLineDash([]);
    var lens = images["lens.png"];
    if (lens && lens.width) {
      var span2 = Math.min(maxX - minX, maxY - minY) * 0.72;
      ctx.drawImage(lens, (minX + maxX) / 2 - span2 / 2,
        (minY + maxY) / 2 - span2 / 2, span2, span2);
    }
    ctx.restore();
  }

  function drawFlash(ctx, fit, cell, age) {
    // The single most watchable moment in the game: a seat has just paid a
    // move for one certainty.
    var strength = 1 - age / FLASH_MS;
    ctx.save();
    ctx.globalAlpha = Math.max(0, strength);
    ctx.strokeStyle = AMBER;
    ctx.lineWidth = Math.max(2, cellRadius(fit) * 0.24);
    cellPath(ctx, fit, cell);
    ctx.stroke();
    var centre = centreOf(fit, cell);
    ctx.beginPath();
    ctx.arc(centre.x, centre.y,
      cellRadius(fit) * (0.7 + (1 - strength) * 0.9), 0, Math.PI * 2);
    ctx.strokeStyle = C.rgba(AMBER, Math.max(0, strength) * 0.7);
    ctx.lineWidth = Math.max(1, cellRadius(fit) * 0.12);
    ctx.stroke();
    ctx.restore();
  }

  function drawBelief(ctx, box, state, seat, fx, now, hudscale) {
    var size = state.size;
    var fit = fitBoard(box, size, state.mode);
    var view = (state.seats || [])[seat] || {};
    var mine = occupantName(seat);
    drawGrid(ctx, fit, "rgba(242, 232, 216, 0.05)");
    drawEdges(ctx, fit);
    var known = cellSet(size, view.known);
    var guessed = cellSet(size, view.guess);
    // Sensed empty: a faint dot whose opacity decays with staleness, so a
    // belief going stale is visible as it fades.
    (view.sensedEmpty || []).forEach(function (entry) {
      var cell = cellOf(size, entry.cell);
      if (cell < 0 || known[cell]) return;
      var age = Math.max(0, (state.ply || 0) - (entry.ply || 0));
      var alpha = Math.max(0.15, 1 - age / 8);
      var centre = centreOf(fit, cell);
      ctx.save();
      ctx.globalAlpha = alpha;
      ctx.fillStyle = GHOST;
      ctx.beginPath();
      ctx.arc(centre.x, centre.y, cellRadius(fit) * 0.16, 0, Math.PI * 2);
      ctx.fill();
      ctx.restore();
    });
    (state.board || []).forEach(function (occupant, cell) {
      if (occupant === mine) drawStone(ctx, fit, cell, seat, 1);
    });
    Object.keys(known).forEach(function (key) {
      var cell = Number(key);
      drawStone(ctx, fit, cell, 1 - seat, 1);
      drawRing(ctx, fit, cell, PAPER, false);
    });
    Object.keys(guessed).forEach(function (key) {
      var cell = Number(key);
      if (known[cell]) return;
      drawStone(ctx, fit, cell, 1 - seat, 0.35);
      drawRing(ctx, fit, cell, C.rgba(SEAT_HEX[1 - seat], 0.8), true);
      // Once the ply resolves, a correct guess takes an amber tick and a
      // wrong one a ghost cross.
      var truth = (state.board || [])[cell];
      if (state.plies > 0) {
        var right = truth === occupantName(1 - seat);
        var centre = centreOf(fit, cell);
        ctx.save();
        ctx.font = "700 " + Math.round(cellRadius(fit) * 0.9) + "px " +
          BOARD_FONT;
        ctx.textAlign = "center";
        ctx.textBaseline = "middle";
        ctx.fillStyle = right ? AMBER : GHOST;
        ctx.fillText(right ? "\u2714" : "\u2718", centre.x, centre.y);
        ctx.restore();
      }
    });
    if (fx.flashAt && now - fx.flashAt < FLASH_MS && fx.flashCell >= 0 &&
        fx.flashSeat === seat) {
      drawFlash(ctx, fit, fx.flashCell, now - fx.flashAt);
    }
    return fit;
  }

  function occupantName(seat) {
    return seat === 0 ? "seat0" : "seat1";
  }

  function draw(ctx, canvas, images, view) {
    var w = canvas.width;
    var h = canvas.height;
    var state = view.state || {};
    var now = view.now || Date.now();
    var hudscale = view.hudscale || 1;
    var floor = images["arena_floor.png"];
    if (floor && floor.width) {
      ctx.fillStyle = ctx.createPattern(floor, "repeat");
    } else {
      ctx.fillStyle = "#16110d";
    }
    ctx.fillRect(0, 0, w, h);
    ctx.fillStyle = "rgba(18, 13, 9, 0.45)";
    ctx.fillRect(0, 0, w, h);
    if (!state.board || !state.size) return;
    var boxes = viewports(w, h, hudscale);
    var nameMap = view.nameMap;
    drawCaption(ctx, boxes.truth, "THE BOARD", PAPER, hudscale);
    drawTruth(ctx, boxes.truth, state, images, view.fx, now, hudscale);
    for (var seat = 0; seat < 2; seat++) {
      var alias = ((state.seats || [])[seat] || {}).name || ("Seat " + seat);
      var who = nameMap ? nameMap.seat(seat) : alias;
      drawCaption(ctx, boxes.belief[seat],
        C.clampName(who).toUpperCase() + " SEES", SEAT_HEX[seat], hudscale);
      drawBelief(ctx, boxes.belief[seat], state, seat, view.fx, now,
        hudscale);
    }
  }

  // ---- Readouts ------------------------------------------------------------

  function modeWord(state, narrow) {
    if (state.mode === "phantom-ttt") {
      return narrow ? "PHANTOM TTT" : "PHANTOM TIC-TAC-TOE";
    }
    return (narrow ? "HEX " : "DARK HEX ") + state.size + "\u00d7" +
      state.size;
  }

  function clockText(state, nameMap) {
    if (!state || !state.size) return "PLY 0";
    var narrow = (window.innerWidth || 1280) <= 360;
    var parts = [modeWord(state, narrow)];
    parts.push("PLY " + (state.plies || 0) + " / " + (state.maxPlies || 0));
    if (state.gameDone) {
      parts.push("FINAL");
    } else {
      var seat = state.mover || 0;
      var who = nameMap ? nameMap.seat(seat) :
        ((state.seats || [])[seat] || {}).name || ("SEAT " + seat);
      parts.push(C.clampName(who).toUpperCase() + " TO MOVE");
    }
    return parts.join(" \u00b7 ");
  }

  function tensionLabel(state, seat) {
    var view = (state.seats || [])[seat] || {};
    var distance = view.distToWin;
    if (typeof distance !== "number" || distance >= 99) return "\u2014";
    return String(distance);
  }

  function fogShare(state, seat) {
    // The share of the opponent's stones this seat has proven.
    var them = (state.seats || [])[1 - seat] || {};
    var mine = (state.seats || [])[seat] || {};
    var total = them.stones || 0;
    if (!total) return 0;
    return Math.max(0, Math.min(1, (mine.discovered || 0) / total));
  }

  function updateScorebug(container, state, nameMap, assetBase) {
    if (!container || !state || !state.seats) return;
    var html = "";
    state.seats.forEach(function (seat, index) {
      var alias = seat.name || ("Seat " + index);
      var policy = nameMap ? nameMap.seat(index) : (seat.policy || alias);
      var acting = !state.gameDone && state.mover === index;
      var say = seat.say || "";
      html += '<div class="plate ' + SEAT_CLASS[index] + '">' +
        '<img class="plate-avatar" alt="" src="' +
        assetUrl(assetBase, index === 0 ? "soldier_red_front.png" :
          "soldier_blue_front.png") + '">' +
        '<span class="plate-name">' + C.escapeHtml(C.clampName(policy)) +
        '<span class="plate-alias">' + C.escapeHtml(alias) + "</span></span>" +
        (acting ? '<span class="plate-it">\u25b6</span>' : "") +
        '<span class="plate-score plate-stones">' + (seat.stones || 0) +
        "</span>" +
        '<span class="plate-label label-stones">stones</span>' +
        '<span class="plate-score plate-tension">' +
        tensionLabel(state, index) + "</span>" +
        '<span class="plate-label label-tension">' +
        (state.mode === "phantom-ttt" ? "line in" : "to connect") +
        "</span>" +
        '<span class="plate-fog"><span class="plate-fog-fill" style="width:' +
        Math.round(fogShare(state, index) * 100) + '%"></span></span>' +
        '<span class="plate-say">' +
        C.escapeHtml(say.slice(0, MAX_SAY_LEN)) + "</span>" +
        "</div>";
    });
    if (container.dataset.html !== html) {
      container.dataset.html = html;
      container.innerHTML = html;
    }
  }

  // ---- Feed ----------------------------------------------------------------

  // `ctx` is the object the inherited renderFeed threads through the event
  // list in order, so the board as it stood at each event can be rebuilt
  // here -- which is what lets a sense line say what the window actually
  // showed and a guess line resolve to a tick or a cross.
  function feedBoard(ctx, event) {
    if (!ctx.fogBoard) ctx.fogBoard = {};
    return ctx.fogBoard;
  }

  function feedText(event, nameMap, ctx) {
    var board = feedBoard(ctx, event);
    var size = feedSize;
    function who(seat) { return C.clampName(nameMap.seat(seat)); }
    switch (event.kind) {
      case "start":
        return "Board set \u2014 two cogs, one board, and no sight of " +
          "the enemy.";
      case "sense":
        var parts = [];
        var anchor = cellOf(size, event.anchor);
        var span = feedSense || 2;
        if (anchor >= 0) {
          var row = Math.floor(anchor / size);
          var col = anchor % size;
          for (var i = 0; i < span; i++) {
            for (var j = 0; j < span; j++) {
              var r = row + i;
              var c = col + j;
              if (r >= size || c >= size) continue;
              var cell = r * size + c;
              var holder = board[cell];
              parts.push(nameOf(size, cell) + " " +
                (holder === undefined ? "empty" :
                  holder === event.seat ? "yours" :
                    who(holder) + "'s"));
            }
          }
        }
        return who(event.seat) + " senses " + event.anchor +
          (parts.length ? " \u2014 " + parts.join(", ") : "");
      case "attempt":
        var line;
        if (event.result === "occupied") {
          var holder2 = board[cellOf(size, event.cell)];
          line = who(event.seat) + " plays " + event.cell +
            " \u2014 OCCUPIED: " +
            (holder2 === undefined ? "someone" : who(holder2)) +
            " is already there";
        } else {
          line = who(event.seat) + " plays " + event.cell + " \u2014 placed";
          board[cellOf(size, event.cell)] = event.seat;
        }
        if ((event.guess || []).length) {
          line += " \u00b7 guesses " + event.guess.map(function (name) {
            var holder3 = board[cellOf(size, name)];
            var right = holder3 !== undefined && holder3 !== event.seat;
            return name + (right ? " \u2714" : " \u2718");
          }).join(", ");
        }
        return line;
      case "win":
        var path = event.path || [];
        if (event.how === "line") {
          return who(event.seat) + " takes the line " + path.join("\u2013");
        }
        return who(event.seat) + " connects " + path[0] + "\u2013" +
          path[path.length - 1];
      case "end":
        if (event.reason === "deadline") {
          return "The episode clock stopped play \u2014 scored on distance.";
        }
        switch (event.ending) {
          case "connection": return "Complete \u2014 the chain is joined.";
          case "line": return "Complete \u2014 the line is made.";
          case "board-full":
            return "Complete \u2014 the board is full and no line exists.";
          case "ply-cap":
            return "Complete \u2014 the ply cap; scored on distance.";
          default: return "Complete.";
        }
      default: return event.kind;
    }
  }

  function endColumns(results) {
    return {
      heads: ["score", "stones", "probes", "discovered", "guess acc."],
      cell: function (i) {
        var accuracy = (results.guessAccuracy || [])[i];
        return [
          ((results.scores || [])[i] || 0).toFixed(2),
          (results.stones || [])[i] || 0,
          (results.probes || [])[i] || 0,
          (results.discovered || [])[i] || 0,
          typeof accuracy === "number" ?
            Math.round(accuracy * 100) + "%" : "\u2014"
        ];
      }
    };
  }

  function verdictResults(results) {
    // The inherited endcard reads `rounds` for its title; this game counts
    // plies. Hand it an aliased copy rather than editing a copied line.
    if (!results) return results;
    var copy = Object.assign({}, results);
    copy.rounds = results.plies;
    copy.maxRounds = results.maxPlies;
    return copy;
  }

  // ---- Effects -------------------------------------------------------------

  function makeEffects(size) {
    var seen = 0;
    var fx = { flashAt: 0, flashCell: -1, flashSeat: -1, senseAt: 0,
      senseAnchor: "", winAt: 0 };
    return {
      absorb: function (events, quiet) {
        var now = Date.now();
        for (; seen < events.length; seen++) {
          var event = events[seen];
          var animate = !quiet || seen >= events.length - 1;
          if (event.kind === "attempt" && event.result === "occupied") {
            fx.flashAt = animate ? now : 0;
            fx.flashCell = cellOf(size, event.cell);
            fx.flashSeat = event.seat;
          } else if (event.kind === "sense") {
            fx.senseAt = animate ? now : 0;
            fx.senseAnchor = event.anchor;
          } else if (event.kind === "win") {
            fx.winAt = animate ? now : 0;
          }
        }
      },
      reset: function () {
        seen = 0;
        fx.flashAt = 0; fx.flashCell = -1; fx.flashSeat = -1;
        fx.senseAt = 0; fx.senseAnchor = ""; fx.winAt = 0;
      },
      view: function () { return fx; }
    };
  }

  function hudscale() {
    var raw = getComputedStyle(document.documentElement)
      .getPropertyValue("--hudscale");
    var value = parseFloat(raw);
    return isNaN(value) ? 1 : value;
  }

  function makeRenderer(canvas, assetBase, onReady) {
    var ctx = canvas.getContext("2d");
    loadAssets(assetBase, function (images) {
      onReady({
        draw: function (view) { draw(ctx, canvas, images, view); }
      });
    });
  }

  // ---- Drivers -------------------------------------------------------------

  function attachLive(options) {
    // options: {canvas, feed, status, clock, scorebug, endscreen,
    //           assetBase, wsPath, onFrame}
    C.setFeedText(feedText);
    C.setEndColumns(endColumns);
    makeRenderer(options.canvas, options.assetBase, function (renderer) {
      var latest = null;
      // Player pages get no policyNames -- a seat must not learn who is
      // behind the other one -- so their map degrades to the aliases.
      var nameMap = C.makeNameMap([], null, []);
      var effects = null;
      var scheme = location.protocol === "https:" ? "wss://" : "ws://";
      var url = scheme + location.host + options.wsPath;

      function setStatus(text, live) {
        if (!options.status) return;
        options.status.textContent = text;
        options.status.classList.toggle("live", !!live);
      }

      function connect() {
        var socket = new WebSocket(url);
        socket.onmessage = function (frame) {
          var data = JSON.parse(frame.data);
          if (data.type === "state" || data.type === "final") {
            if (data.type === "state") latest = data;
            if (latest) {
              nameMap = C.makeNameMap(seatNames(latest), latest.policyNames,
                []);
              if (!effects) {
                effects = makeEffects(latest.size || 5);
                feedSize = latest.size || 5;
                feedSense = latest.sense || 0;
              }
              effects.absorb(latest.events || []);
              if (options.feed) {
                C.renderFeed(options.feed, latest.events || [], nameMap,
                  undefined);
              }
              if (options.clock) {
                options.clock.textContent = clockText(latest, nameMap);
              }
              updateScorebug(options.scorebug, latest, nameMap,
                options.assetBase);
            }
            if (data.type === "final") {
              C.updateEndscreen(options.endscreen, verdictResults(data), true,
                nameMap);
            }
            if (latest && (latest.done || latest.gameDone)) {
              setStatus("final", false);
            }
          }
          if (options.onFrame) options.onFrame(data);
        };
        socket.onclose = function () {
          setStatus("disconnected", false);
          setTimeout(connect, 2000);
        };
        socket.onopen = function () { setStatus("live", true); };
      }
      connect();

      function seatNames(data) {
        return (data.seats || []).map(function (s) { return s.name; });
      }

      (function frame() {
        if (latest && effects) {
          renderer.draw({
            state: latest,
            nameMap: nameMap,
            fx: effects.view(),
            hudscale: hudscale(),
            now: Date.now()
          });
        }
        requestAnimationFrame(frame);
      })();
    });
  }

  function attachReplay(options) {
    // options: {canvas, feed, scrub, playButton, label, clock, scorebug,
    //           endscreen, assetBase, payload, onFirstFrame}
    C.setFeedText(feedText);
    C.setEndColumns(endColumns);
    var payload = options.payload;
    var events = payload.events || [];
    var states = payload.states || [];
    var config = payload.config || {};
    var nameMap = C.makeNameMap(payload.names, payload.policyNames, []);
    feedSize = config.size || 5;
    feedSense = config.sense || 0;
    var index = 0;
    var playing = true;
    var lastStep = 0;
    var announced = false;

    makeRenderer(options.canvas, options.assetBase, function (renderer) {
      var effects = makeEffects(config.size || 5);
      var scrub = C.buildScrub(options.scrub, events, function (next) {
        playing = false;
        setIndex(next, true);
      });
      if (options.playButton) {
        options.playButton.onclick = function () {
          playing = !playing;
          if (playing && index >= events.length) setIndex(0, true);
        };
      }

      function currentState() {
        var state = states[Math.min(index, states.length - 1)] ||
          { board: [], seats: [], size: config.size, mode: config.mode };
        if (!state.size && config.size) {
          state = Object.assign({}, state, { size: config.size,
            mode: config.mode, sense: config.sense });
        }
        return state;
      }

      function setIndex(next, jumped) {
        index = Math.max(0, Math.min(next, events.length));
        scrub.update(index);
        if (jumped) effects.reset();
        effects.absorb(events.slice(0, index), jumped);
        if (options.feed) C.renderFeed(options.feed, events, nameMap, index);
        if (options.label) {
          options.label.textContent = index + " / " + events.length;
        }
        var state = currentState();
        if (options.clock) {
          options.clock.textContent = clockText(state, nameMap);
        }
        updateScorebug(options.scorebug, state, nameMap, options.assetBase);
        // Every seek dismisses the endcard: it only shows once playback
        // has actually reached the end.
        C.updateEndscreen(options.endscreen, verdictResults(payload.results),
          index >= events.length && events.length > 0, nameMap);
      }
      setIndex(0, true);

      (function frame(timestamp) {
        var shown = index > 0 ? events[index - 1] : null;
        var stepMs = DWELL.other;
        if (shown) {
          if (shown.kind === "attempt") {
            stepMs = shown.result === "occupied" ? DWELL.occupied :
              DWELL.placed;
          } else if (DWELL[shown.kind] !== undefined) {
            stepMs = DWELL[shown.kind];
          }
        }
        if (playing && index < events.length &&
            timestamp - lastStep > stepMs) {
          lastStep = timestamp;
          setIndex(index + 1, false);
        }
        if (options.playButton) {
          var running = playing && index < events.length;
          options.playButton.textContent = running ? "\u275a\u275a" : "\u25b6";
          options.playButton.classList.toggle("on", running);
        }
        renderer.draw({
          state: currentState(),
          nameMap: nameMap,
          fx: effects.view(),
          hudscale: hudscale(),
          now: Date.now()
        });
        if (!announced) {
          announced = true;
          // The FIRST DRAWN FRAME, not a parsed payload: the shell sets
          // data-replay-loaded and posts its `ready` bridge from here, so
          // an embedding page can never sample an unpainted shell
          // (chorus 3c11c953, 2026-08-24).
          document.documentElement.setAttribute("data-replay-loaded", "true");
          if (typeof options.onFirstFrame === "function") {
            options.onFirstFrame();
          }
        }
        requestAnimationFrame(frame);
      })(0);
    });
  }

  window.FogRenderer = {
    attachLive: attachLive,
    attachReplay: attachReplay,
    renderFeed: C.renderFeed,
    bindFeedToggle: C.bindFeedToggle
  };
})();

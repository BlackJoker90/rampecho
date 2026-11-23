---
name: pre-dv-restore-check
description: Exhaustive check that the format and depth held for leaving Dolby Vision (pre_dv_color_format, pre_dv_max_bpc) stay right over every order of WebUI page, API, self-test and port 85 requests, with the real handlers. Use when a change touches how pre_dv_* are saved or dropped (webui_apply_config, forget_pre_dv_format_depth, pgenerator_cmd's SET_PGENERATOR_CONF, renderer_dv_conf_active, normalize_dv_transport_conf, pgenerator_conf_set_pair, the page's applySettings body), or when the check reports a violation.
---

# pre-DV restore check

**Property.** While Dolby Vision is on, `pre_dv_color_format` and
`pre_dv_max_bpc` in PGenerator.conf hold the format and depth the conf had
just before the current DV visit began, when the WebUI began it, and are
empty when a port 85 client began it. The self-test's own switches
(`selftest:1`) never change the visit.

**Harm when broken.** Leaving DV, `webui_apply_config` gives these values
back (its `%pre_dv_back` branch), so wrong held values put the output on a
format or depth the user never had before DV (the HDR10 YCbCr 4:4:4
10-bit after SDR RGB 8-bit case in the `forget_pre_dv_format_depth`
comment, command.pm).

This check proves the values held, not the give-back from them: the rules
of the `%pre_dv_back` branch (which format and depth come back, the
signal-check fallback) are tested by `t/dv_leave_mode_only.t` and
`t/dv_leave_note_first_request.t` (local-only `t/`; run them for a change
there).

The check is a breadth-first search over conf states. Each step is one
whole request run through the real code against a temp conf file; a
violation comes back as the shortest request sequence.

## Steps

All commands run from the repo root.

1. **Does the change touch the verified code?**
   `perl .claude/skills/pre-dv-restore-check/dv_visit_check.pl --stale`
   lists every covered function (see Coverage) whose source differs from
   the sync commit. Exit 0: none differs, so this check has nothing new to
   say. Exit 1: go on. Uncommitted edits count, so run it mid-change.
2. **Run the check.**
   `perl .claude/skills/pre-dv-restore-check/dv_visit_check.pl`
   (depth 5, about 75 s on the Mac; `--depth 4`, about 20 s, for a quicker
   look while editing; `--tree DIR` for another copy, e.g. `git archive`
   of a commit unpacked in `$TMPDIR`). Done when it exits 0, or exits 1 and
   you have classified the violation (step 3).
3. **Read the result.**
   - `OK up to 5 requests ...`: the property holds for every sequence of
     at most 5 requests. Report it with that bound. The sync commit gave
     8032 states at depth 5; far fewer means requests stopped reaching
     their states (a mock the handlers now need), so find out why first.
   - `VIOLATION: ...` (exit 1) with the shortest request sequence:
     classify it as described in "Real bug or modeling error", below.
   - `CHECK FAILED` or a load error (exit 2): a handler died, a module did
     not load, or a request kind never changed the conf (checked from
     `--depth 2` on; the message names them: the handler now refuses them). Rerun without `--quiet` for the
     error, and give the checker what the handler needs.
4. **When a change of the property is intended** (the maintainer decides,
   e.g. port 85 visits keep the values): change `violation()` and
   `next_visit()` in `dv_visit_check.pl` and the Property paragraph above
   together, in the same edit. When the page or the self-test post other
   bodies, change the requests in `dv_visit_check.pl` to match.
5. **Prove the check can still fail.**
   `perl .claude/skills/pre-dv-restore-check/mutants.pl` breaks the covered
   code in temp copies (the tree is never written) and must print `CAUGHT`
   for every mutant. `SETUP FAILED` means the mutated text moved: update
   that mutant's exact text to the new code. A mutant whose break became
   intended behaviour in step 4 is replaced by one that breaks the new
   rule.
6. **Move the sync commit**, only after the covered code is committed,
   step 2 exits 0, step 5 catches every mutant, and you have read each
   function step 1 listed and confirmed that the requests, mocks and
   ghost below still describe it. Set the sync commit below to
   `git rev-parse --short HEAD` and the state count in step 3 to the new
   run's; `--stale` then exits 0.

## Real bug or modeling error

A violation is a finding only after these checks; otherwise it is a
modeling error, and the fix goes into the checker, followed by step 5.

1. **Each step is possible.** Steps are a WebUI page post (the flags and
   the whole form, as `applySettings` in webui-app.js posts them, without
   `signal_mode`), an API post naming the mode (alone, or with a format
   and depth), a self-test switch (the bodies of pgen_selftest.pl's
   `@scenarios` and `restore_user_state`), or one port 85 command. The conf
   outlives a client, so a port 85 step followed by a WebUI step is always
   reachable (the client disconnects in between), even where
   `webui_signal_owner` refuses WebUI posts while calibration software
   other than HCFR and Resolve holds the signal.
2. **No mock carries the violation.** Mocked: the root helper (`sudo`;
   conf writes go through the real `pgenerator_conf_set_pair` and always
   answer OK; everything else answers OK and does nothing),
   `webui_selftest_running` (1 exactly for self-test posts),
   `webui_signal_owner` (nobody), the display (`signal_display_caps`: no
   EDID), the mode (`signal_mode_info`: 1080p60), the board (Pi 4), and
   the renderer start, snapshot and refusal helpers. Past modeling error:
   an early version mocked `renderer_dv_conf_active` as dv_status only and
   reported Low Latency DV page, port 85 DV_STATUS:0, Standard DV page as
   a violation; the real function reads all three DV flags. That function
   stays real, and mutant M6 keeps the case.
3. **The ghost matches the code's intent.** `next_visit()` decides who
   began a visit (WebUI, port 85, or no claim for the self-test) and what
   the conf held before it. Compare it with the comments at
   `forget_pre_dv_format_depth` (command.pm) and the pre_dv block of
   `webui_apply_config` (webui.pm, the `if(!$selftest && !grep` line).
4. **Replay it.** The sequence runs real code, so a violation that passes
   1-3 is a finding. Report it in the code's words (the printed sequence
   and conf), with the level it reached: on the Pi, replay the steps
   through the WebUI and port 85 and read pre_dv_* in
   /etc/PGenerator/PGenerator.conf after each (the `pi` skill; `pgen-pi
   busy` first; maintainer's OK for anything that changes the signal).
   Keep the property as it is and leave product code to the maintainer's
   word.

## What a pass covers

- Requests: the 38 kinds listed in `dv_visit_check.pl` ("requests"),
  with color_format 0/1/2, max_bpc 8/10/12, from two start confs (SDR RGB
  8-bit, SDR YCbCr 4:4:4 10-bit).
- Bound: every order of at most 5 requests (8032 states at the sync
  commit; `--depth 6` also passed there, 15328 states in 180 s), not a
  fixpoint; an unbounded run of an earlier, smaller request set did not
  close within 10 minutes.
- A request is one indivisible step. The code holds no lock across one
  (read at the sync commit): `webui_apply_config` reloads the conf at its
  start (webui.pm 11154) and writes it through the helper near its end
  (11692) with no lock call in between; `pgenerator_cmd`
  (command.pm 2836-3030) takes none either; the WebUI runs in its own
  thread (daemon.pm 45) and port 85 in `pattern_daemon` (daemon.pm 3591);
  `webui-apply.lock` covers only the renderer restart worker. A port 85
  command landing inside that window is not covered.
- Process memory outside the conf (the WebUI's remembered range) starts
  each request as after a daemon start.
- Not covered: the give-back itself (see above), Calman (pattern_daemon
  in daemon.pm calls `forget_pre_dv_format_depth` inline on its DV paths,
  judging dv_status alone), PiTPG (`pitpg_dv_kind_write`, pitpg.pm), the
  Pi tools that post pre_dv_* themselves, `pre_dv_rgb_quant_range`, a root
  helper that fails or times out, EDID-dependent DV settings, other boards
  and modes, and the renderer itself.

Known note, not the property: after `port 85 SET_PGENERATOR_CONF_DV_STATUS:1`
the in-memory conf lacks the `dv_map_mode=0` that the helper pairs with
`dv_metadata=2` in the file (`normalize_dv_transport_conf` writes through
`set_pgenerator_conf_runtime_multi`, which does not apply the pairing to
memory). Seen in the real handlers under this checker, not on the Pi. In
the daemon that memory is shared by all threads (variables.pm 457) and
holds the gap until the WebUI next reads the conf (`webui_config_json`,
every GET /api/config, or an apply). Every reader found maps missing and 0
alike (dv_metadata 2). The check prints it as a note; a new key in that
note is new.

Tool: plain Perl 5 running the real handlers (macOS /usr/bin/perl 5.34.1
with threads; nothing to install). The handlers are callable and take
milliseconds, so the real code serves as the model; a hand model of
`webui_apply_config` would drift from it.

## Coverage

Sync commit: `6815b96b`

- `usr/share/PGenerator/webui.pm`: `webui_apply_config`, `webui_reload_pgenerator_conf`, `webui_selftest_running`
- `usr/share/PGenerator/command.pm`: `forget_pre_dv_format_depth`, `remember_webui_rgb_quant_range`, `pg_conf_write_checked`, `set_pgenerator_conf_runtime_multi`, `conf_after_helper_writes`, `normalize_dv_transport_conf`, `normalize_conf_write`, `renderer_dv_conf_active`, `renderer_conf_read`, `pgenerator_cmd`
- `usr/bin/PGenerator_cmd.pl`: `pgenerator_conf_set_pair`
- `usr/bin/pgen_selftest.pl`: `@scenarios`, `apply_config`, `restore_user_state`
- `usr/share/PGenerator/webui-app.js`: `applySettings`, `dvTransportDefaults`, `dvMetadataForMapMode`

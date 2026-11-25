## tests/test_manifest.nim — packaging.
##
## The manifest, `compose.yaml` and the design note's seat count are three
## declarations of the same fact, and nothing downstream re-checks them: a
## missing `num_agents` schedules zero episodes, a hand-written image
## placeholder hard-fails `coworld build`, and a game runnable without
## game credential drift can silently turn model seats into fallback policies.

import std/[json, os, sets, strutils]
import helpers

const Seats = 3

proc repoRoot(): string =
  currentSourcePath().parentDir().parentDir()

proc composeServiceName(text: string): string =
  ## The single source of the manifest's image placeholder: the first entry
  ## under `services:` (LEARNINGS 2026-08-23 lantern — `coworld build` maps
  ## `services.<name>` to `{{<NAME>_IMAGE}}` and hard-fails anything else).
  var inServices = false
  for rawLine in text.splitLines():
    let line = rawLine.split('#')[0]
    if line.strip().len == 0:
      continue
    if not line.startsWith(" ") and not line.startsWith("\t"):
      inServices = line.strip() == "services:"
      continue
    if inServices and line.strip().endsWith(":") and
        line.len - line.strip(leading = true, trailing = false).len == 2:
      return line.strip().strip(chars = {':'})
  ""

when isMainModule:
  let root = repoRoot()
  let manifest = parseJson(readFile(root / "coworld_manifest_template.json"))
  let compose = readFile(root / "compose.yaml")

  # ---- the image placeholder is DERIVED from the compose service name ------
  let service = composeServiceName(compose)
  doAssert service == "ecos", "compose service is " & service
  let placeholder = "{{" & service.toUpperAscii() & "_IMAGE}}"
  doAssert placeholder == "{{ECOS_IMAGE}}"
  doAssert manifest{"game"}{"runnable"}{"image"}.getStr() == placeholder,
    "the game runnable image must be " & placeholder
  doAssert "image: coworld-ecos:latest" in compose
  doAssert "platform: linux/amd64" in compose

  # ---- num_agents in EVERY variant and in the certification fixture --------
  doAssert manifest{"variants"}.len >= 2
  var variantIds: HashSet[string]
  for variant in manifest{"variants"}:
    let id = variant{"id"}.getStr()
    variantIds.incl(id)
    doAssert variant{"description"}.getStr().len > 0,
      "variant " & id & " has no description (0.1.42 requires one)"
    doAssert variant{"game_config"}{"num_agents"}.getInt() == Seats,
      "variant " & id & " must set num_agents = " & $Seats
    doAssert variant{"game_config"}{"players"}.len == Seats
  doAssert "standard" in variantIds and "harsh-spring" in variantIds

  let fixture = manifest{"certification"}{"game_config"}
  doAssert fixture{"num_agents"}.getInt() == Seats,
    "the certification fixture must set num_agents = " & $Seats
  doAssert fixture{"players"}.len == Seats
  doAssert manifest{"certification"}{"players"}.len == Seats

  # ---- declared players: native prompt player first, scripted baselines separate
  # Release certification seats the native model player at seat 0 alongside
  # every declared scripted baseline so every declared player ID is certified.
  var declared: HashSet[string]
  doAssert manifest{"player"}.len == 3
  let nativePlayer = manifest{"player"}[0]
  doAssert nativePlayer{"id"}.getStr() == "ecos-player",
    "native model player must be listed first"
  doAssert nativePlayer.hasKey("env"),
    "native model player must declare native Coworld LLM env"
  doAssert nativePlayer{"env"}{"COWORLD_LLM_ENABLED"}.getStr() == "true",
    "native model player must set COWORLD_LLM_ENABLED=true"
  doAssert nativePlayer{"env"}{"COWORLD_LLM_MODEL"}.getStr() ==
    "anthropic/claude-haiku-4.5",
    "native model player must set default COWORLD_LLM_MODEL"
  doAssert not nativePlayer{"env"}.hasKey("PLAYER_SCRIPTED"),
    "native model player must not set PLAYER_SCRIPTED"
  for player in manifest{"player"}:
    let id = player{"id"}.getStr()
    declared.incl(id)
    for field in ["id", "type", "name", "description"]:
      doAssert manifest{"player"}.len > 0 and
        player{field}.getStr().len > 0,
        "player " & id & " is missing " & field
    doAssert player{"type"}.getStr() == "player"
    doAssert player{"image"}.getStr() == placeholder
    doAssert player{"run"}[0].getStr() == "/bin/ecos-player"
  doAssert declared ==
    ["ecos-player", "ecos-steward", "ecos-opportunist"].toHashSet()
  doAssert manifest{"certification"}{"players"}[0]{"player_id"}.getStr() ==
    "ecos-player",
    "certification seat 0 must be the native model player"
  var seated: HashSet[string]
  for entry in manifest{"certification"}{"players"}:
    let pid = entry{"player_id"}.getStr()
    doAssert pid in declared, "certification player " & pid & " is undeclared"
    seated.incl(pid)
  doAssert seated == declared,
    "certification must seat every declared player ID; seated " & $seated &
    " vs declared " & $declared

  # ---- the static replay bundle, never a pod -------------------------------
  doAssert manifest{"game"}{"replay_viewer"}{"bundle"}.getStr() ==
    "static-replay-viewer"
  doAssert not manifest{"game"}.hasKey("replay_runnable")

  # ---- the 0.1.42 upload contract ------------------------------------------
  doAssert manifest.hasKey("$schema")
  doAssert manifest{"tags"}.len >= 3
  doAssert manifest{"episode_timeout_minutes"}.getInt() == 20,
    "episode_timeout_minutes is TOP LEVEL (extra_forbidden under game)"
  doAssert not manifest{"game"}.hasKey("episode_timeout_minutes")
  doAssert manifest{"game"}{"runnable"}{"type"}.getStr() == "game"
  doAssert manifest{"game"}{"runnable"}{"run"}[0].getStr() == "/bin/ecos"

  let schema = manifest{"game"}{"config_schema"}
  doAssert schema.hasKey("$schema")
  doAssert schema{"type"}.getStr() == "object"
  doAssert schema{"additionalProperties"}.getBool() == false
  var required: HashSet[string]
  for item in schema{"required"}:
    required.incl(item.getStr())
  doAssert "tokens" in required
  # Every key any variant or the fixture sets must be a declared property,
  # because additionalProperties is false and the CLI validates both.
  for block2 in [manifest{"variants"}[0]{"game_config"},
                 manifest{"variants"}[1]{"game_config"}, fixture]:
    for key, _ in block2.pairs:
      doAssert schema{"properties"}.hasKey(key),
        "config key " & key & " is not in game.config_schema.properties"

  doAssert not manifest["game"]["runnable"].hasKey("env"),
    "model credentials belong to players, not the game"

  var allowedReasons: HashSet[string]
  for item in manifest{"game"}{"results_schema"}{"properties"}{"reason"}{"enum"}:
    allowedReasons.incl(item.getStr())
  doAssert allowedReasons == ["complete", "deadline"].toHashSet(),
    "results_schema.reason must not include forfeit: " & $allowedReasons

  # ---- docs and protocols --------------------------------------------------
  doAssert manifest{"game"}{"docs"}{"readme"}{"type"}.getStr() == "text"
  doAssert manifest{"game"}{"docs"}{"readme"}{"value"}.getStr().len > 200
  doAssert manifest{"game"}{"docs"}{"pages"}.len >= 1
  for page in manifest{"game"}{"docs"}{"pages"}:
    doAssert page{"id"}.getStr().len > 0
    doAssert page{"title"}.getStr().len > 0
    doAssert page{"content"}{"type"}.getStr() == "text"
    doAssert page{"content"}{"value"}.getStr().len > 100
  for name in ["player", "global"]:
    doAssert manifest{"game"}{"protocols"}{name}{"type"}.getStr() == "text"
    doAssert manifest{"game"}{"protocols"}{name}{"value"}.getStr().len > 100,
      "game.protocols." & name & " must carry the real protocol text"

  # ---- the manifest agrees with the engine ---------------------------------
  let defaults = defaultGameConfig()
  let standard = manifest{"variants"}[0]{"game_config"}
  doAssert standard{"generations"}.getInt() == defaults.generations
  doAssert standard{"ticksPerGeneration"}.getInt() ==
    defaults.ticksPerGeneration
  doAssert standard{"capGrass"}.getInt() == defaults.capGrass
  doAssert standard{"capGrazers"}.getInt() == defaults.capGrazers
  doAssert standard{"capPredators"}.getInt() == defaults.capPredators
  doAssert manifest{"game"}{"name"}.getStr() == "ecos"

  # ---- the harsh-spring variant is declared in exactly one place -----------
  # `tests/helpers.nim`'s `harshSpringConfig` is what gate (a) of
  # `tests/test_feasibility.nim` actually runs. Nothing else ties it to the
  # manifest block the platform ships, so an edit to either alone would ship
  # a variant the ecological oracle never gated.
  block:
    var harsh: JsonNode = nil
    for variant in manifest{"variants"}:
      if variant{"id"}.getStr() == "harsh-spring":
        harsh = variant{"game_config"}
    doAssert not harsh.isNil
    let gated = harshSpringConfig(1)
    for (name, shipped) in [
      ("initGrass", gated.initGrass),
      ("initGrazers", gated.initGrazers),
      ("initPredators", gated.initPredators),
      ("grassGain", gated.grassGain),
      ("generations", gated.generations),
      ("ticksPerGeneration", gated.ticksPerGeneration),
      ("capGrass", gated.capGrass),
      ("capGrazers", gated.capGrazers),
      ("capPredators", gated.capPredators)
    ]:
      doAssert harsh{name}.getInt() == shipped,
        "harsh-spring." & name & " is " & $harsh{name}.getInt() &
        " in the manifest and " & $shipped & " in the config gate (a) runs"

  # ---- a variant is identifiable in the bytes it records -------------------
  # `configJson` writes `config.variant` into every replay, but the platform
  # can only set what the schema declares (`additionalProperties: false`), so
  # without the property every hosted replay recorded "standard".
  block:
    let declared = manifest{"game"}{"config_schema"}{"properties"}{"variant"}
    doAssert not declared.isNil, "config_schema must declare `variant`"
    var allowed: HashSet[string]
    for value in declared{"enum"}:
      allowed.incl(value.getStr())
    for variant in manifest{"variants"}:
      let id = variant{"id"}.getStr()
      doAssert id in allowed, "variant " & id & " is not in the variant enum"
      if id != "standard":
        doAssert variant{"game_config"}{"variant"}.getStr() == id,
          "variant " & id & " must record its own id in the replay"
    var config = defaultGameConfig()
    config.update("""{"variant": "harsh-spring"}""")
    doAssert config.configJson(){"variant"}.getStr() == "harsh-spring",
      "the recorded config block must carry the variant the platform set"

  # ---- policies.json: two prompt champions plus the two baselines ----------
  let policies = parseJson(readFile(root / "tools" / "ci" / "policies.json"))
  doAssert policies.len == 4
  var prompt = 0
  var scriptedNames: HashSet[string]
  for policy in policies:
    doAssert policy{"name"}.getStr().startsWith("ecos-")
    doAssert policy{"run"}.getStr() == "/bin/ecos-player"
    if policy{"env"}.hasKey("PLAYER_PROMPT"):
      inc prompt
      doAssert policy{"env"}{"PLAYER_PROMPT"}.getStr().len > 200
    else:
      scriptedNames.incl(policy{"env"}{"PLAYER_SCRIPTED"}.getStr())
  doAssert prompt == 2, "both champions must be PLAYER_PROMPT policies"
  doAssert scriptedNames == ["steward", "opportunist"].toHashSet()
  doAssert policies[1]{"player"}.getStr() ==
    "ply_bac48eb1-662e-44f8-973d-f3e016dccf5d",
    "champion #2 must be uploaded while daveey-1 is the active player"

  echo "test_manifest: ok"

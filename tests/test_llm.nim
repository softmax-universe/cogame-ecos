## Player-side prompt parsing and the visible-observation policy boundary.

import std/json
import curly
import helpers
import ../src/ecos/[llm, scripted, sim, sim_types]

proc assertRejected(body: proc()) =
  var rejected = false
  try:
    body()
  except EcosError:
    rejected = true
  doAssert rejected

when isMainModule:
  let config = standardConfig(4)
  let world = newSim(config)
  let client = newLlmClientFor("test-key-not-used")
  doAssert not client.disabled

  # Single JSON object: bare, ```json fenced, and plain ``` fenced.
  doAssert extractJsonObject("""{"a":2}""")["a"].getInt() == 2
  doAssert extractJsonObject("```json\n{\"a\":2}\n```")["a"].getInt() == 2
  doAssert extractJsonObject("```\n{\"a\":2}\n```")["a"].getInt() == 2
  doAssert extractJsonObject("  ```JSON\r\n{\"a\":2}\r\n```  ")["a"].getInt() == 2

  # Reject surrounding prose, extra objects, multiple fences, non-objects.
  for bad in [
    """Here is my action: {"a":2}""",
    """{"a":2} hope this helps""",
    "Sure:\n```json\n{\"a\":2}\n```",
    "```json\n{\"a\":2}\n```\nextra",
    """{"a":1} {"b":2}""",
    "```json\n{\"a\":1}\n```\n```json\n{\"b\":2}\n```",
    "```python\n{\"a\":2}\n```",
    """[1, 2, 3]""",
    """42""",
    """   """,
    "```json\n{\"a\":2}"
  ]:
    let sample = bad
    assertRejected(proc() = discard extractJsonObject(sample))

  # Strict integer doctrine parsing with optional say/notes.
  let parsed = parseDecision(spGrazers, parseJson("""
    {"doctrine":{"birth_threshold":120,"bite":9,"flee_range":90,
                 "herd":55},"say":"holding","notes":"n"}"""))
  doAssert parsed.fields == [120, 9, 90, 55]
  doAssert not parsed.clamped
  doAssert parsed.say == "holding" and parsed.notes == "n"

  let optionalDefaults = parseDecision(spGrazers, parseJson("""
    {"doctrine":{"birth_threshold":120,"bite":9,"flee_range":90,"herd":55}}"""))
  doAssert optionalDefaults.fields == [120, 9, 90, 55]
  doAssert optionalDefaults.say == "" and optionalDefaults.notes == ""

  let clamped = parseDecision(spPredators, parseJson("""
    {"doctrine":{"birth_threshold":9999,"hunt_range":-5,
                 "rest_energy":700,"spread":40}}"""))
  doAssert clamped.clamped
  doAssert clamped.fields == [400, 40, 400, 40]

  # Reject legacy shims: string/float values, inlined doctrine, extra keys, bad say/notes.
  for badPayload in [
    """{"doctrine":{"birth_threshold":"120","bite":9,"flee_range":90,"herd":55}}""",
    """{"doctrine":{"birth_threshold":120,"bite":8.7,"flee_range":90,"herd":55}}""",
    """{"birth_threshold":120,"bite":9,"flee_range":90,"herd":55}""",
    """{"doctrine":{"birth_threshold":120,"bite":9,"flee_range":90,"herd":55,"extra":1}}""",
    """{"doctrine":{"birth_threshold":120,"bite":9,"flee_range":90,"herd":55},"extra":1}""",
    """{"doctrine":{"birth_threshold":120,"bite":9,"flee_range":90,"herd":55},"say":123}""",
    """{"doctrine":{"birth_threshold":120,"bite":9,"flee_range":90,"herd":55},"notes":[]}"""
  ]:
    let sample = parseJson(badPayload)
    assertRejected(proc() = discard parseDecision(spGrazers, sample))

  # Reject legacy PLAYER_SCRIPTED and species aliases.
  doAssert parseScriptKind("") == skNone
  doAssert parseScriptKind("steward") == skSteward
  doAssert parseScriptKind("opportunist") == skOpportunist
  for legacyScript in ["1", "true", "yes", "greedy", "unknown"]:
    let sample = legacyScript
    assertRejected(proc() = discard parseScriptKind(sample))

  doAssert speciesFromName("grass") == spGrass
  doAssert speciesFromName("grazers") == spGrazers
  doAssert speciesFromName("predators") == spPredators
  for legacySpecies in ["grazer", "predator"]:
    let sample = legacySpecies
    assertRejected(proc() = discard speciesFromName(sample))

  for slot in 0 .. 2:
    let species = world.roleOf[slot]
    let view = world.observationJson(slot)
    doAssert view["role"].getStr() == RoleNames[species]
    for kind in [skSteward, skOpportunist]:
      doAssert scriptedDoctrineFromView(view, kind).fields ==
        scriptedDoctrine(world, species, kind)

  let refusal = Response(code: 200, body: $ %*{
    "content": [], "stop_reason": "refusal"})
  assertRejected(proc() = discard client.textOf(refusal, "", "http://stub"))

  let view = world.observationJson(world.seatOf[spPredators])
  doAssert view["rules"]["killCap"].getInt() == KillCap
  doAssert view["rules"]["killBase"].getInt() == KillBase
  echo "test_llm: ok"

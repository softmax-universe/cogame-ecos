## Complete doctrine parsing and validation, without inference or fallbacks.

import std/[json, strutils, unicode]
import sim_types, events

type
  Decision* = object
    fields*: Doctrine
    clamped*: bool
    say*: string
    notes*: string
    source*: DoctrineSource
    latencyMs*: int

proc cleanText*(text: string, limit: int): string =
  ## Text over the cap is cut at a RUNE boundary with the cut marked. A byte
  ## cut put invalid UTF-8 into a bullwhip replay and only a strict parser
  ## found it (LEARNINGS 2026-08-22).
  result = text.strip()
  if result.runeLen <= limit:
    return
  result = result.runeSubStr(0, limit - 1) & "…"

proc cleanSay*(text: string): string =
  cleanText(text.replace("\n", " ").replace("\r", " "), MaxSayLen)

proc cleanNotes*(text: string): string =
  cleanText(text, MaxNotesLen)

proc intField(node: JsonNode, name: string): int =
  ## A doctrine value must be a JSON integer.
  if node.isNil or node.kind == JNull:
    raise newException(EcosError, "doctrine field missing: " & name)
  if node.kind != JInt:
    raise newException(EcosError, "doctrine field must be an integer: " & name)
  node.getInt()

proc optionalStringField(payload: JsonNode, name: string): string =
  if not payload.hasKey(name):
    return ""
  let node = payload[name]
  if node.kind != JString:
    raise newException(EcosError, name & " must be a string")
  node.getStr()

proc parseDecision*(species: Species, payload: JsonNode,
    allowWireFields = false): Decision =
  ## Strict parser: requires a JSON object with a `doctrine` object containing
  ## exactly the four integer fields for `species`, plus optional string `say`
  ## and `notes`. Out-of-range integers are clamped and recorded as such.
  if payload.isNil or payload.kind != JObject:
    raise newException(EcosError, "decision payload must be a JSON object")
  for key, _ in payload.pairs:
    if key in ["doctrine", "say", "notes"]:
      continue
    if allowWireFields and key in ["type", "generation", "source", "latency_ms"]:
      continue
    raise newException(EcosError, "unexpected decision field: " & key)
  result.say = cleanSay(optionalStringField(payload, "say"))
  result.notes = cleanNotes(optionalStringField(payload, "notes"))
  if not payload.hasKey("doctrine") or payload["doctrine"].kind != JObject:
    raise newException(EcosError, "decision must contain a doctrine object")
  let source = payload["doctrine"]
  if source.len != 4:
    raise newException(EcosError,
      "doctrine must contain exactly 4 fields for " & RoleNames[species])
  var raw: Doctrine
  for i in 0 .. 3:
    let name = DoctrineFieldNames[species][i]
    raw[i] = intField(source{name}, name)
  let checked = clampDoctrine(species, raw)
  result.fields = checked.fields
  result.clamped = checked.clamped

# Comet and Galaxy Link: what's missing

Nebula sends Claude's replies from the Create screen to you through Comet, as a Galaxy Link handoff (`POST /v1/tasks` with `"to": "comet"`, power `imessage`). Comet isn't connected to Galaxy Link yet, so those handoffs wait in Link's queue. Nothing is lost: the replies also show in the Create screen. As you asked, I haven't written any code in CometAI. This is what it would need.

## What I checked

In `Zebra0723/CometAI`, branches `claude/laughing-shannon-7j3yyk`, `claude/imessage-agent-abonfq`, `claude/nice-knuth-5l429p`, `claude/comet-owner-invite` and `claude/laughing-hypatia-8wayzv`: no file mentions Galaxy, `galaxyd` or port 7740. The only "Galaxy" hit is a bundle-identifier string in `macos/app/Resources/Info.plist`.

## What Comet needs

Galaxy Link ships a drop-in client for TypeScript bodies, `galaxy/src/client.ts` in NovaAI (copy the file; no imports beyond Node's). In Comet's server process:

1. **Join as `comet`.**
   ```ts
   const link = new GalaxyLink("comet", { name: "Comet", version });
   link.run({ onTask, onInbox });
   ```
   Link already knows Comet's profile (powers `imessage`, `reach_phone`, …; surface `phone`) and its intro.

2. **Handle handoffs (`onTask`).** Nebula's tasks look like this:
   ```json
   { "from": "nebula", "to": "comet", "power": "imessage",
     "title": "Nebula: Pinky Up",
     "instructions": "Text this to the user exactly as written, from Nebula:\n\n<Claude's reply>" }
   ```
   Comet should text the part after the blank line to the owner verbatim (not through its own model, so nothing gets rephrased), then return `{ ok: true, result: "sent" }`. Other bodies' tasks can go through Comet's normal agent.

3. **Deliver results (`onInbox`).** Results and messages Link routes to the phone arrive here; text them to the owner.

4. **Answer approvals by text (optional, once the approvals patch is in).** When a body asks for a yes or no, Comet could text the question and turn a "yes" or "no" reply into `link.decide(id, approve, "text")`. Nebula's thumbs and Comet's text then race, and the first answer wins.

## What decides the approvals path

Galaxy Link had no approvals API, so I wrote one as a patch, in this repo at `galaxy-patch/` (see its README). Bodies ask with `link.ask(title)`, which resolves the moment the answer is given. Nebula long-polls the pending list, so the camera arms immediately and a thumbs up or down reaches the waiting body at once.

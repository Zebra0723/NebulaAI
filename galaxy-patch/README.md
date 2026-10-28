# Galaxy Link approvals

A patch for `galaxy/` in NovaAI. It's kept here because Nebula's work stays inside this repo. Apply it to your NovaAI checkout yourself:

```bash
galaxy-patch/apply.sh ~/path/to/NovaAI
```

It applies cleanly to `claude/nice-knuth-5l429p`, runs `bun test` (the 19 existing tests plus 6 new ones, all passing), and leaves the change uncommitted for you to review. Then restart galaxyd:

```bash
launchctl kickstart -k gui/$(id -u)/ai.galaxy.link
```

## API

All endpoints use Link's usual token and `X-Galaxy-Body` header.

| Call | Who | What |
|---|---|---|
| `POST /v1/approvals` `{title, detail?, ttlSeconds?}` | the body asking | Creates a pending approval (default 120 s to answer). Posts to Galaxy Chat. |
| `GET /v1/approvals/pending?since=V&wait=25` | Nebula | `{version, pending}` as soon as the pending set differs from version `V`: a long poll, so the camera arms the moment a body starts waiting. |
| `POST /v1/approvals/:id/decide` `{decision: "approve"\|"reject", via?}` | any other body | First answer wins; an asker can't answer itself. Wakes the asker immediately. |
| `GET /v1/approvals/:id?wait=25` | the asker | Returns the moment it's answered (or expires). |
| `POST /v1/approvals/:id/cancel` | the asker | Withdraws it. |

`client.ts` gains `link.ask(title, {detail, ttlSeconds})`, which creates an approval and resolves with the answer, and `link.decide(id, approve, via)`.

Unanswered approvals expire at their deadline and leave the pending list (which wakes Nebula's poll too). Nebula's profile gains the powers `gestures` and `approvals`.

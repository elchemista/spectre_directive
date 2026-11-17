# Migrate Directive integration from 0.3 to 0.4

This guide covers integration with Spectre `~> 0.4.0`. Install the compatible
package versions shown in the [README](../README.md), then follow the ownership
and callback changes below. Satellite versions remain independent of core.

## Move ownership, preserve capabilities

| Earlier integration | AgentServer 0.4 |
| --- | --- |
| Agent `handle_directive` / automatic Turn handler | Separate Server uses pure `directive` helper and handles correlated results |
| A resident mission actor is started by the integration | Store reducer state in Server assigns; standalone OTP runtime remains an explicit alternative |
| Reducer invokes callbacks/functions as part of a runtime | Server performs configured cognition or proposes effects; pure helper only returns requests |
| Plan/policy acceptance treated as effect permission | Mission confirmation stays distinct from GAM mandate/admission |

1. Keep the Stack installation and supported provider/configuration choices.
   Change any dependency pins to the compatible package versions or reviewed source refs.
2. Keep routes/classification declarations in the Agent, set `server: MyApp.Server`,
   and move execution callbacks to `use Spectre.Server, tools: MyApp.AI`.
3. Return the context containing generated helper commands. Handle actual tagged
   results in `handle_result/3`; there is no synchronous helper result and no import
   of invented <code>Spectre.Directive.directive/3</code> functions.
4. For consequential work, configure AgentServer allowed operations and consent
   continuations where required. Installing a package does not authorize end-user
   effects. Follow the [GAM manifest](https://spectre.guide/en/governed-act-model).
5. Choose and supervise the actual runtime resources and checkpoint Store. Keep
   handles outside durable assigns; use portable result/state representations.
6. Exercise recovery with your application's real scope, storage and provider
   contracts. A changed checkpoint fingerprint requires an explicit core migration;
   old Instance snapshots are not automatically AgentServer snapshots.

## What remains available

The pure reducer and optional OTP mission runtime remain supported. The Agent extension, `handle_directive` and Turn-handler examples describe the retained legacy integration. In AgentServer 0.4, use the pure reducer helper rather than starting another mission owner implicitly.

See the [retained reference](REDUCER_AND_OTP_RUNTIME.md) for these APIs and
[0.4 helper/lifecycle contracts](SPECTRE_0_4.md) for the new integration. Migration
is an ownership/API change, not a promise that every legacy convenience now
implicitly routes through AgentServer or GAM.

## Skill Servers and the shared GAM

A mounted Skill may have a separate Server, state and checkpoint. It automatically
reuses the root AgentServer's GAM Domain, authority ledger and execution boundary;
no Skill Host, second Domain or manual ingress is part of this migration. Keep
root operation permissions and mount `governed:` references aligned. Proposal
provenance remains recorded, confirmations stay bound to the exact Skill and
presentation, and timer closure cannot erase a Duty. Parallel workers remain
subject to the same kernel admission laws.

See [the package integration guide](SPECTRE_0_4.md#server-lifecycle-and-skills) and the
[core Skill ownership and consent contract](https://github.com/elchemista/spectre/blob/0.4.0/docs/SKILLS.md).

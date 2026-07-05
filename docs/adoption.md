# Adopting genswarms-delegated-spend

This guide walks the **five-item adoption contract** (design spec §3.2): what
a consuming app supplies to run the permit lane on its own authority. The
worked example throughout is the package's own reference consumer —
`contracts/src/examples/EchoSpendRouter.sol` and its suite
`contracts/test/EchoSpendRouterSuite.t.sol`. Where Echo deliberately stops
short (recoverability, persistence), the guide describes what a real
consumer's version looks like.

The posture to internalize first: **generic as a package, never generic as a
deployed authority.** Every app deploys its OWN immutable router subclass with
exactly one typed money-moving action. Nothing deployed is shared between
apps; a grant to one router instance is unusable via another (pinned by the
cross-router isolation test).

The five items:

1. A concrete router extending `SpendRouter`
2. The funds destination
3. Intent calls + typed result handling
4. A storage adapter (the `Keeper.Store` behaviour)
5. Config + deploys

---

## 1. The concrete router

Extend the abstract `SpendRouter` with **one** typed external action plus its
`...WithPermit` variant. That's the whole contract — Echo is ~60 lines:

```solidity
contract EchoSpendRouter is SpendRouter {
    constructor(address token_, address anchor_, address delegationManager_)
        SpendRouter(token_, anchor_, delegationManager_) {}

    function routerType() external pure override returns (bytes32) {
        return keccak256("ECHO_SPEND_ROUTER");
    }

    // Beneficiary-binding derivation: the destination COMMITS to the user.
    function destinationFor(bytes32 topic, address beneficiary) public view returns (address) {
        return address(uint160(uint256(
            keccak256(abi.encode(address(this), anchor, topic, beneficiary)))));
    }

    // Delegation-lane shape (M2): user is msg.sender.
    function pay(bytes32 topic, uint256 amount, bytes32 orderId) external {
        _pay(msg.sender, topic, amount, orderId);
    }

    // Permit lane (M1): keeper submits, user = permit signer.
    function payWithPermit(bytes32 topic, uint256 amount, bytes32 orderId,
        address owner, uint256 deadline, uint8 v, bytes32 r, bytes32 s) external {
        _applyPermit(owner, amount, deadline, v, r, s);
        _pay(owner, topic, amount, orderId);
    }

    function _pay(address user, bytes32 topic, uint256 amount, bytes32 orderId) internal {
        address destination = destinationFor(topic, user);
        _routeSpend(user, destination, amount, orderId);
        emit EchoPaid(topic, user, destination, amount, orderId);
    }
}
```

What the base gives you (never re-implement):

- `_routeSpend(user, destination, amount, orderId)` — the ONLY token-moving
  path: one `transferFrom(user → destination)` with an exact-delivery check,
  a reentrancy lock, and `orderId` consumed before the external call.
- `_applyPermit(owner, value, deadline, v, r, s)` — EIP-2612 application with
  front-run tolerance (if `permit` reverts but the standing allowance already
  covers `value`, proceed; otherwise `PermitRejected`).
- Constructor immutables `token`, `anchor`, `delegationManager` (pass
  `address(0)` for a permit-only M1 deploy — the router never *calls* the
  DelegationManager, it's introspection only), plus the `version()` /
  `routerType()` / `orderConsumed(orderId)` views.

What you must get right:

- **Credit-recipient derivation is structural.** The `user` handed to
  `_routeSpend` is the permit signer in the `...WithPermit` variant and
  `msg.sender` in the plain variant — never a parameter the keeper chooses.
  Echo's `payWithPermit` passes `owner` (whose signature `_applyPermit` just
  checked); a submitted-but-unsigned "user" parameter is the classic mistake
  the invariant suite catches.
- **The destination derivation takes that `user` as the beneficiary input.**
  Echo's `destinationFor(topic, beneficiary)` commits to the beneficiary in
  the hash — a corrupt `topic` still lands funds at an address bound to the
  user, never redirectable to a third party. The real version of this shape
  derives the destination from an escrow vault's claim-bound deposit view
  with `claimTo = user`.
- **The `...WithPermit` tail is a convention:** the last five arguments are
  `owner, deadline, v, r, s` in that order — that is what
  `DelegatedSpend.Keeper.PermitLane.build_call/3` appends after your action
  args (see item 3).
- **One action.** The ABI-pin test enforces exactly your declared
  state-changing selectors, nothing payable, no receive/fallback, and none of
  the forever-absent surfaces (owner/pause/upgrade/rescue/execute).

⚠ Echo itself is **TEST-ONLY** — its hash destinations have no code, no key,
and no refund path. Never deploy it with a real token.

## 2. The funds destination

Two accepted shapes (spec §3.2 item 2):

- **Claim-bound view derivation**: the destination is read from a contract
  view that commits to the beneficiary *before* funding — e.g. an escrow
  vault's CREATE2 deposit address with `claimTo = user`, so funds landing
  there are recoverable by the user through the vault's permissionless
  claim-bound refund, keeper or no keeper.
- **Typed credit interface**: a vault/credit call whose recipient argument IS
  the derived `user`.

Both halves of the destination rule matter:

1. **Binding** — the derivation takes the structurally derived `user` as the
   beneficiary input. The base cannot express this in Solidity; it is
   enforced by `SpendRouterTestBase` via your destination oracle (item on
   testing below).
2. **Recoverability** — the beneficiary must be able to get funds back out.
   The suite cannot check this generically; it is yours to prove — pin it
   with a funded round-trip through your real refund path in your own
   suite. Echo deliberately fails this half — that is why it is test-only.

## 3. Intent calls + typed result handling

Your product code talks to `DelegatedSpend.Keeper` (a GenServer the app
starts — see item 5 for options):

```elixir
# Register a server-authoritative order. `source` is the TRUSTED runtime
# envelope sender, checked against the keeper's :source_allowlist —
# anything source-shaped inside the payload is inert data.
{:ok, %{order_id: _, order_ref: ref, expires_at: _, amount: _}} =
  Keeper.register_order(keeper, source, %{
    user_ref: user_ref,          # app-derived opaque ref, never a raw platform id
    amount: amount,              # token units; the permit must cover EXACTLY this
    action_args: [...],          # your action's args, in ABI order (order_id inside them
                                 #   is your on-chain idempotency key)
    expected_owner: claim_wallet # optional wallet binding (see below)
  })

# The Mini App drives these two through the intake (item 5), but they are
# plain keeper calls:
{:ok, view} = Keeper.fetch_order(keeper, order_ref, user_ref)
result      = Keeper.execute_with_permit(keeper, order_ref, user_ref, permit)
# result: {:submitted, tx_hash} | {:credited, tx_hash}
#       | {:failed, :not_found | :expired | :no_grant | :reverted | :rpc_timeout}
#       | :unknown

Keeper.order_status(keeper, order_id)   # re-queryable at-least-once results
Keeper.reconcile_boot(keeper)           # call once after start: delivers results
                                        # for txs that mined while the keeper was down
```

Results are also pushed through the `result_fn` option as
`{order_id, result}` tuples. **`{:credited, tx}` means MINED, nothing more**
— it is display-only until your app's own confirmation-depth policy says
otherwise (a conservative first integration credits nothing from the keeper
result at all and lets the app's own chain watcher remain the only
crediting path).

**Swarm-object registration (the message door).** If your intent producer is
itself a GenSwarms object, wire the keeper into the swarm instead of calling
it directly — `DelegatedSpend.Keeper.Object` implements the `ObjectHandler`
contract over the same core:

```elixir
objects: [
  %{name: :spend_keeper,
    handler: DelegatedSpend.Keeper.Object,
    config: %{keeper_opts: %{...the Keeper.start_link opts above...}}}
]
```

Your object registers by returning
`{:send, :spend_keeper, Jason.encode!(%{action: "register_order", order: ...}), state}`
— the keeper checks the framework-stamped sender, not anything in the
payload. Messages are one-way, so **you mint the `order_ref` yourself**
(`Base.encode16(:crypto.strong_rand_bytes(32), case: :lower)`) and put it in
the order; the core enforces format and per-user uniqueness. Binary action
args travel as `0x`-hex strings. The keeper acks with a routed reply you may
ignore. The intake HTTP path is unaffected either way — it stays a
synchronous call into the core.

The keeper builds calldata solely from the **stored** order via
`PermitLane.build_call(action, action_args, permit)` using your pinned action
config:

```elixir
# Echo's would be:
action: %{with_permit_name: "payWithPermit",
          arg_types: [{:bytes, 32}, {:uint, 256}, {:bytes, 32}]}

# a real consumer's looks the same, just with its own action's signature:
action: %{with_permit_name: "openPositionWithPermit",
          arg_types: [{:bytes, 32}, {:uint, 8}, {:uint, 256}, {:uint, 256}, {:bytes, 32}]}
```

(`arg_types` cover YOUR args only; the `[owner, deadline, v, r, s]` permit
tail is appended by the lane.)

If your credit machinery scans addresses derived from a wallet-on-file, set
`expected_owner` on every order AND start the keeper with
`require_owner_binding: true` — then a permit signed by any other wallet
typed-fails, and an order that *loses* its binding (e.g. a storage bug) fails
CLOSED instead of executing. Set both; the external audit's one critical
finding (F1) was exactly a SQL adapter dropping this field.

Shape your product seam so every failure is `{:error, _}` and the caller
renders its UI exactly as before — the app's ordinary payment path is the
permanent fallback for every typed failure.

## 4. The storage adapter

Implement the `DelegatedSpend.Keeper.Store` behaviour
(`objects/spend_keeper/store.ex`). The callbacks (all take your opaque
`ref` term first — the keeper is started with `store: {YourModule, ref}`):

| Callback | Purpose |
|---|---|
| `put_grant/4`, `get_grant/3`, `grants_for/2`, `revoke_grant/3` | grant registry (stored in M1, redeemed in M2) |
| `record_spend/4`, `spent_since/3` | per-`user_ref` spend accounting |
| `put_order/2`, `get_order/2`, `get_order_by_ref/3` | server-authoritative orders |
| `consume_order/3` | atomic single consumption |
| `put_inflight/3`, `update_inflight_hash/3`, `resolve_inflight/3`, `list_inflight/1` | in-flight submissions + boot reconciliation |

Semantics every implementation MUST reproduce
(`DelegatedSpend.Keeper.MemoryStore` in the same file is the reference; the
package's tests are the executable contract):

- Orders are **immutable** after `put_order` and consumed **atomically
  exactly once**: under concurrent `consume_order` calls, exactly one caller
  gets `{:ok, order}` — pin this in your adapter's suite against your real
  database, with genuinely concurrent callers.
- All reads are scoped by `user_ref` — a wrong `user_ref` is
  indistinguishable from not-found.
- Grants are keyed by app-supplied opaque `user_ref` — never raw platform
  ids; never log grant bodies.
- `list_inflight/1` powers `reconcile_boot`.
- Round-trip **every** order field — including the optional
  `expected_owner`. Dropping it silently is the audit's F1; pair your adapter
  with `require_owner_binding: true` so that failure mode is CLOSED.

Money-lane bookkeeping should not be in-memory-only in production —
`MemoryStore` is reference semantics, not a production store.

## 5. Config + deploys

- **Router deploy + attestation.** Deploy your concrete router with its
  immutables (`token`, your `anchor`, `delegationManager` — `address(0)` for
  M1), then run:

  ```bash
  scripts/attest.sh <rpc-url> <deployed-address> YourRouter.sol YourRouter
  ```

  It diffs the deployed runtime bytecode against your local build modulo
  immutables, prints the **runtime codehash** (pin it in your boot
  verification env, e.g. `SPEND_ROUTER_CODEHASH`), and echoes the
  introspection views. Feed the pins to
  `DelegatedSpend.Keeper.BootCheck.verify(rpc_mod, rpc, %{chain_id: id,
  codehashes: %{addr => hash}})` before enabling the keeper — wrong network
  or wrong contract fails closed.

- **Mini App build on your domain.** `webapp/` is a static, zero-dependency
  build parameterized by `webapp/config.json`:
  `version, chainId, token, tokenName, tokenVersion, router, intakeUrl,
  actionLabel`. Serve it over HTTPS on the app's domain and attach it as the
  bot's WebApp button; order links are `<miniapp-url>?order=<order_ref>`.
  The `version` stamp must match the package tag — the intake 409s a stale
  build at runtime.

- **Intake mounted.** The package ships PURE handlers —
  `DelegatedSpend.Intake.handle_order/2` and `handle_grant/2`, each
  `params → {status, body_map}` — and YOU supply the HTTP serving and the
  fail-closed bind (loopback unless explicitly published). The ctx:

  ```elixir
  %{bot_token: bot_token,          # Telegram initData HMAC key
    max_age_s: 900,                # initData freshness window
    user_ref_fn: fn user_id -> ... end,  # verified Telegram id -> opaque user_ref
    keeper: keeper_pid,
    pinned: %{chain_id: id, token: token, router: router, version: version},
    rate: {DelegatedSpend.Intake.Rate.start(60), 30}}   # optional
  ```

  The Mini App POSTs `{intakeUrl}/orders` and `{intakeUrl}/grants` with
  `init_data` in the body. A ~60-line Plug over Bandit is all the serving
  glue takes: route first, cap the body (64 kB → 413), decode-error → 400 —
  auth still happens inside the handlers.

- **Keeper key provisioned.** The keeper signs with its OWN key
  (`SPEND_KEEPER_PRIVATE_KEY` in the template) — **never** the app's
  bot/treasury key; the compromise blast radii must stay separate. Fund it
  for gas only. See `.env.example` for the full environment template,
  including which values are required vs optional.

## The testing bar

**Your router is not adopted until the inherited invariant suite passes.**
Make your Foundry test contract inherit
`contracts/test/SpendRouterTestBase.sol` and implement its seven hooks —
`EchoSpendRouterSuite.t.sol` is the literal template:

| Hook | You supply |
|---|---|
| `_deployRouter(address token_)` | deploy your router against the suite's mock token |
| `_router()` | return it as `SpendRouter` |
| `_executeAs(asUser, amount, orderId)` | run your plain action pranked as `asUser`, canned args |
| `_executeWithPermit(submitter, ownerPk_, amount, orderId, deadline, v, r, s)` | run your `...WithPermit` variant pranked as `submitter` |
| `_expectedDestination(user_)` | the **destination oracle**: expected funds destination for canned args + user |
| `_allowedMutators()` | the exact state-changing function names (your two selectors) |
| `_artifactPath()` | e.g. `"out/YourRouter.sol/YourRouter.json"` for the ABI pin |

The suite then enforces for free: conservation + zero router residual (both
lanes, fuzzed), credit-recipient-is-signer-not-submitter, `orderId`
idempotency, zero-arg floors, permit front-run tolerance / expired-permit /
allowance-boundary / over-signed-value semantics, and the single-action
no-admin ABI pin. The destination oracle is how the beneficiary-binding
invariant — inexpressible in the Solidity base — gets enforced against YOUR
derivation. Beyond the suite: prove recoverability yourself (item 2), and
add app-side keeper/store/intake tests on the package's seams (typical set:
real-database consumption races, fail-closed UI pins, a golden vector for
your `user_ref` derivation).

## Invariants the adopter must not weaken

The authoritative list is the package `README.md` security section (and spec
§10); the ones adoption work most often bumps into:

- One typed action per router; no owner/pause/upgrade/rescue/execute — ever.
- Credit recipient structurally derived; destination beneficiary-bound AND
  recoverable by the beneficiary.
- `orderId` idempotent per router instance — namespace your order ids per
  instance (the package keeper mints 32 random bytes per order).
- Orders are server-authoritative and immutable; only the envelope sender
  (allowlist) can register them; the permit must cover exactly the order
  amount; TTL is the keeper's job, not the permit deadline's.
- Simulation before EVERY broadcast; a failing simulation spends zero gas.
- Keeper key ≠ bot key. `initData` never logged; raw platform ids never
  persisted (opaque `user_ref` only). Intake fail-closed: loopback bind by
  default, 401 before any work, strict byte-for-byte grant validation
  against pinned config.
- Treat `{:credited, _}` as display-only until your own confirmation depth.

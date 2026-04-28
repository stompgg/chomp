1)
introducing extruder.

extruder is an **experimental** **vibe-coded** transpiler that converts Solidity into TypeScript.

if this sounds insane to you, let me explain why. if you're already insane, feel free to jump to the end, download the package, and start extruding.

2)
okay, so WHY do something this atrocious?

two main reasons: gas efficiency, and observability.

3)
traditionally, devs have been hesitant to include verbose events in smart contracts because of the extra gas costs. we've had projects like shadow or ghost logs try to fix this with "fake" logs that don't get shipped to prod. but this locks you into their infra, and it still requires you to write events at the end of the day.

event logs are elegant, but also very blunt. you cannot substitute them for traces without emitting a ton of data

4)
extruder lets you run your contracts anywhere you have a JS runtime. on your client, on your server, etc. importantly, it gives you an entire trace of any transaction.

5)
how well does it work? i'm already dogfooding extruder in prod! it's used on the game client for @stompdotgg. stomp was a very events heavy game--any given round might produce 10-20 logs for stats being altered, statuses being applied, etc. etc.

using extruder has saved around 15-20% in gas costs!

6) 
one extra bonus is having your contracts in TypeScript makes them more legible to LLMs. most agents have some JS sandbox, so they can easily fuzz and understand your integrations.

7) 
note that extrude does NOT SUPPORT ALL OF SOLIDITY OR THE EVM. for example, it uses the native Map  and does NOT calculate storage slots correctly. some Yul will break! the goal here was to support a good enough fast enough subset of Solidity.

anyway, it's in alpha here under AGPL v3. try it out!
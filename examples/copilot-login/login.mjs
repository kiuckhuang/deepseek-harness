#!/usr/bin/env node
/**
 * Sign in to a pi-ai catalog provider through the harness authorization seam,
 * storing the credential in the real DSH home (`~/.dsh/.credentials.yaml`) so
 * every `dsh` profile — headless, web, SDK — authenticates with it afterwards.
 *
 * No shipped profile mounts the authorization service yet, so this tool boots
 * its own minimal composition (`cordis.yml` beside this script): the
 * authorization seam, the file-backed credential store, and the dormant
 * `llm-pi-ai` adapter that registers one login flow per installed catalog
 * provider.
 *
 * Usage: node login.mjs [provider-id]   (default: github-copilot)
 */

import { createInterface } from 'node:readline/promises'
import { dirname, join } from 'node:path'
import { fileURLToPath, pathToFileURL } from 'node:url'

import { Context } from '../../vendor/cordis/lib/index.js'
import Loader from '../../vendor/loader/lib/index.js'
import Include from '../../vendor/include/lib/index.js'
import Authorization, { AuthorizationDeclinedError } from '../../packages/credentials/authorization/lib/index.js'
import CredentialsLocal from '../../packages/credentials/credentials-local/lib/index.js'
import LlmRuntime from '../../packages/llm/llm/lib/index.js'
import * as PiAi from '../../packages/llm/llm-pi-ai/lib/index.js'
import { credentialKeyId } from '../../packages/credentials/credentials/lib/index.js'

const here = dirname(fileURLToPath(import.meta.url))
const providerId = process.argv[2] ?? 'github-copilot'

/** Render one seam notice for the terminal. */
function printNotice(notice) {
  console.log('')
  console.log(notice.message)
  if (notice.url !== undefined) console.log(`\n  Open:  ${notice.url}`)
  if (notice.code !== undefined) console.log(`  Code:  ${notice.code}`)
}

/** Answer one seam prompt from stdin. A blank text answer is legitimate —
 * pi-ai's Copilot OAuth asks for an optional Enterprise URL and expects blank
 * for github.com — so decline only via an explicit `cancel` (or Ctrl-C). */
async function answerPrompt(prompt) {
  const rl = createInterface({ input: process.stdin, output: process.stdout })
  try {
    if (prompt.kind === 'select') {
      for (const [index, option] of prompt.options.entries()) {
        console.log(`  ${index + 1}. ${option.label}`)
      }
      const raw = await rl.question(`${prompt.message} (number) `)
      const picked = prompt.options[Number(raw.trim()) - 1]
      if (picked === undefined) throw new AuthorizationDeclinedError()
      return picked.id
    }
    const answer = await rl.question(`${prompt.message} `)
    if (answer.trim().toLowerCase() === 'cancel') throw new AuthorizationDeclinedError()
    return answer
  } finally {
    rl.close()
  }
}

const ctx = new Context()
ctx.baseUrl = pathToFileURL(here + '/').href
await ctx.plugin(Loader)
ctx.loader.builtins.include = Include
const modules = new Map([
  ['@deepseek-ai/dsh-llm', LlmRuntime],
  ['@deepseek-ai/dsh-authorization', Authorization],
  ['@deepseek-ai/dsh-credentials-local', CredentialsLocal],
  ['@deepseek-ai/dsh-llm-pi-ai', PiAi],
])
ctx.loader.internal = {
  version: 'v2',
  async import(specifier) {
    const mod = modules.get(specifier)
    if (mod === undefined) throw new Error(`unexpected Loader import: ${specifier}`)
    return mod
  },
}
await ctx.loader.create({
  name: 'cordis:include',
  config: { path: pathToFileURL(join(here, 'cordis.yml')).href },
})
await ctx.loader.await()

const flow = ctx.authorization.list().find(entry => credentialKeyId(entry.key) === providerId)
if (flow === undefined) {
  const known = ctx.authorization.list().map(entry => credentialKeyId(entry.key)).sort()
  console.error(`No login flow is registered for "${providerId}".`)
  console.error(`Registered flows: ${known.join(', ')}`)
  await ctx.fiber.dispose()
  process.exit(1)
}

console.log(`Signing in to ${flow.label} (${providerId}).`)
console.log(`Methods offered: ${flow.methods.map(method => method.id).join(', ')}`)

const controller = new AbortController()
process.on('SIGINT', () => { controller.abort(new Error('interrupted')) })

let outcome
try {
  outcome = await ctx.authorization.begin({
    key: flow.key,
    // OAuth first, which is what every catalog flow lists as its preferred method.
    method: flow.methods[0].id,
    interaction: {
      notify: printNotice,
      prompt: answerPrompt,
    },
    signal: controller.signal,
  })
} catch (error) {
  console.error('')
  console.error(`Sign-in failed: ${error.message}`)
  await ctx.fiber.dispose()
  process.exit(1)
}

if (outcome.status !== 'authorized') {
  console.log('')
  console.log('Sign-in cancelled; nothing was stored.')
  await ctx.fiber.dispose()
  process.exit(1)
}

const stored = await ctx.credentials.describeRecord(flow.key)
console.log('')
console.log(`Signed in. The ${stored.kind} credential is stored in the DSH credential store`)
console.log('(~/.dsh/.credentials.yaml), self-refreshing; every dsh profile reads it from there.')
console.log('')
console.log('Next steps — declare the route in ~/.dsh/settings.yaml and select a model:')
console.log('')
console.log('  llm-pi-ai:')
console.log(`    ${providerId}: {}`)
console.log('')
console.log('  agent-default-model:')
console.log(`    provider: ${providerId}`)
console.log('    model: <a model id from the provider catalog>')
console.log('')
console.log('Settings re-read per request, so no restart is needed.')
await ctx.fiber.dispose()

#!/usr/bin/env node
/**
 * End-to-end check for the sign-in tool: boots the same minimal composition
 * but points the settings provider at the REAL user settings document
 * (`~/.dsh/settings.yaml`), asserts the `github-copilot` route registered
 * live from it, and streams one tiny request through the OAuth grant.
 *
 * Usage: node verify.mjs [model]   (default: claude-haiku-4.5)
 */

import { Context } from '../../vendor/cordis/lib/index.js'
import Loader from '../../vendor/loader/lib/index.js'
import Include from '../../vendor/include/lib/index.js'
import LlmRuntime, { createUserMessage, BlockAssembler } from '../../packages/llm/llm/lib/index.js'
import FileSettingsProvider from '../../packages/settings/settings-file/lib/index.js'
import CredentialsLocal from '../../packages/credentials/credentials-local/lib/index.js'
import Authorization from '../../packages/credentials/authorization/lib/index.js'
import * as PiAi from '../../packages/llm/llm-pi-ai/lib/index.js'

const here = new URL('.', import.meta.url).pathname
const model = process.argv[2] ?? 'claude-haiku-4.5'

const ctx = new Context()
ctx.baseUrl = `file://${here}`
await ctx.plugin(Loader)
ctx.loader.builtins.include = Include
const modules = new Map([
  ['@deepseek-ai/dsh-llm', LlmRuntime],
  ['@deepseek-ai/dsh-settings-file', FileSettingsProvider],
  ['@deepseek-ai/dsh-credentials-local', CredentialsLocal],
  ['@deepseek-ai/dsh-authorization', Authorization],
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
  config: { path: `file://${here}cordis-verify.yml` },
})
await ctx.loader.await()

const providers = ctx.llm.listProviders().map(provider => provider.id)
console.log(`Registered provider routes: ${providers.join(', ')}`)
if (!providers.includes('github-copilot')) {
  console.error('github-copilot is not registered — check ~/.dsh/settings.yaml')
  await ctx.fiber.dispose()
  process.exit(1)
}

console.log(`Streaming one request through github-copilot / ${model} …`)
const assembler = new BlockAssembler()
const request = {
  provider: 'github-copilot',
  model,
  messages: [createUserMessage({
    content: [{ type: 'text', text: 'Reply with exactly: OK' }],
    source: { kind: 'plugin', plugin: 'copilot-login-verify' },
  })],
}
for await (const chunk of ctx.llm.stream(request)) assembler.push(chunk)
const reply = assembler.message({
  kind: 'model',
  provider: 'github-copilot',
  model,
})
const text = reply.content
  .filter(block => block.type === 'text')
  .map(block => block.text)
  .join('')
console.log(`Reply: ${text}`)
console.log(`Finish reason: ${JSON.stringify(assembler.finish)}`)
console.log(`Blocks: ${JSON.stringify(reply.content)}`)
console.log(`Usage: ${assembler.usage === undefined ? 'none' : JSON.stringify(assembler.usage)}`)
await ctx.fiber.dispose()

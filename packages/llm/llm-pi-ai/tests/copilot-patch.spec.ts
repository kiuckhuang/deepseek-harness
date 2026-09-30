import { describe, expect, it } from 'vitest'
import type { Api, Model } from '@earendil-works/pi-ai'
import { getBuiltinModels } from '@earendil-works/pi-ai/providers/all'
import { githubCopilotProvider } from '@earendil-works/pi-ai/providers/github-copilot'
import { completeGitHubCopilotCatalog } from '@earendil-works/pi-ai/providers/github-copilot-catalog'

const ID = 'gpt-6.1-sol'

function catalog(provider: 'openai' | 'github-copilot'): Record<string, Model<Api>> {
  return Object.fromEntries(getBuiltinModels(provider).map(model => [model.id, structuredClone(model)]))
}

function inputs(): { copilot: Record<string, Model<Api>>; openai: Record<string, Model<Api>> } {
  const model: Model<Api> = {
    id: ID,
    name: 'GPT-6.1 Sol',
    api: 'openai-responses',
    provider: 'openai',
    baseUrl: 'https://api.openai.com/v1',
    reasoning: true,
    thinkingLevelMap: { low: 'low', high: 'high' },
    input: ['text', 'image'],
    cost: { input: 2, output: 10, cacheRead: 0.1, cacheWrite: 2.5 },
    contextWindow: 272_000,
    maxTokens: 128_000,
    headers: { 'X-OpenAI-Only': 'unused' },
    compat: { supportsToolSearch: true },
  }
  const transport: Model<Api> = {
    ...model,
    id: 'gpt-6-sol',
    name: 'GPT-6 Sol',
    provider: 'github-copilot',
    baseUrl: 'https://api.individual.githubcopilot.com',
    contextWindow: 1_000_000,
    headers: { 'Copilot-Integration-Id': 'vscode-chat' },
    compat: { supportsAdditionalTools: true },
    inputLimits: { images: { resize: { maxWidth: 2000 } } },
  }
  return { copilot: { [transport.id]: transport }, openai: { [ID]: model } }
}

function required(catalog: Readonly<Record<string, Model<Api>>>, id: string): Model<Api> {
  const model = catalog[id]
  if (model === undefined) throw new Error(`fixture lacks ${id}`)
  return model
}

describe('GitHub Copilot dependency patch', () => {
  it('publishes GPT-6.1 Sol in the upstream catalog and provider', () => {
    expect(getBuiltinModels('github-copilot').map(model => model.id)).toContain(ID)
    expect(githubCopilotProvider().getModels().map(model => model.id)).toContain(ID)
  })

  it('combines current model facts with Copilot transport settings without changing its inputs', () => {
    const { copilot, openai } = inputs()
    const original = structuredClone({ copilot, openai })
    const model = required(openai, ID)
    const transport = required(copilot, 'gpt-6-sol')

    const complete = completeGitHubCopilotCatalog(copilot, openai)

    expect(complete[ID]).toEqual({
      ...model,
      provider: 'github-copilot',
      baseUrl: transport.baseUrl,
      contextWindow: transport.contextWindow,
      headers: transport.headers,
      compat: transport.compat,
      inputLimits: transport.inputLimits,
    })
    expect(complete['gpt-6-sol']).toBe(transport)
    expect({ copilot, openai }).toEqual(original)
    expect(completeGitHubCopilotCatalog(complete, openai)).toBe(complete)
  })

  it('adopts updated source metadata without copying OpenAI endpoint settings', () => {
    const { copilot, openai } = inputs()
    const model = required(openai, ID)
    const transport = required(copilot, 'gpt-6-sol')
    model.maxTokens = 256_000
    model.thinkingLevelMap = { high: 'new-high' }
    transport.baseUrl = 'https://api.business.githubcopilot.com'
    transport.contextWindow = 2_000_000
    transport.headers = { 'Editor-Version': 'vscode/new' }

    expect(completeGitHubCopilotCatalog(copilot, openai)[ID]).toMatchObject({
      maxTokens: 256_000,
      thinkingLevelMap: { high: 'new-high' },
      baseUrl: transport.baseUrl,
      contextWindow: 2_000_000,
      headers: transport.headers,
    })
  })

  it('keeps a future native Copilot entry even when the supplement sources disappear', () => {
    const native = { ...required(catalog('github-copilot'), ID), contextWindow: 3_000_000 }
    const copilot = { [ID]: native }

    const complete = completeGitHubCopilotCatalog(copilot, {})

    expect(complete).toBe(copilot)
    expect(complete[ID]).toBe(native)
  })

  it.each(['openai-model', 'copilot-transport', 'api', 'headers', 'compat', 'inputLimits'] as const)(
    'rejects an incompatible dependency catalog missing %s', (field) => {
      const { copilot, openai } = inputs()
      const transport = required(copilot, 'gpt-6-sol')
      switch (field) {
        case 'openai-model': Reflect.deleteProperty(openai, ID); break
        case 'copilot-transport': delete copilot['gpt-6-sol']; break
        case 'api': transport.api = 'anthropic-messages'; break
        case 'headers': delete transport.headers; break
        case 'compat': delete transport.compat; break
        case 'inputLimits': delete transport.inputLimits; break
      }

      expect(() => completeGitHubCopilotCatalog(copilot, openai)).toThrow(/review the pi-ai patch/)
    },
  )
})

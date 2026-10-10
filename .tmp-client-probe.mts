// Replicate collectClientBundles with full rolldown error reporting to find
// which client bundle fails and why.
import { globSync, readFileSync } from 'node:fs'
import { dirname, resolve } from 'node:path'
import { pathToFileURL } from 'node:url'
import { Rolldown } from 'tsdown'

const root = process.cwd()
const manifests = new Map()
for (const path of globSync('packages/*/*/package.json')) {
  const manifest = JSON.parse(readFileSync(path, 'utf8'))
  if (manifest.dsh?.client !== undefined) manifests.set(path, manifest)
}
console.log(`client packages: ${manifests.size}`)
for (const [manifestPath, manifest] of manifests) {
  const dir = dirname(resolve(manifestPath))
  const loaded = await import(pathToFileURL(resolve(dir, 'tsdown.config.ts')).href) as { default: unknown }
  const factory = await loaded.default as (env: object, opts: object) => object | Promise<object>
  const configured = typeof factory === 'function' ? await factory({ env: {} }, { ci: false }) : factory
  const configs = Array.isArray(configured) ? configured : [configured]
  const client = configs.find(config => config.name === `${manifest.name}/client`)
  if (client === undefined) { console.log(`SKIP ${manifest.name}: no client config`); continue }
  try {
    const bundle = await Rolldown.rolldown({
      ...client.inputOptions,
      cwd: dir,
      input: client.entry,
      platform: 'browser',
      transform: client.define === undefined ? {} : { define: client.define },
      plugins: client.plugins ?? [],
      tsconfig: resolve(root, 'tsconfig.base.client.json'),
    })
    await bundle.generate({ format: 'cjs', sourcemap: false })
    await bundle.close()
    console.log(`OK   ${manifest.name}`)
  } catch (error) {
    console.log(`FAIL ${manifest.name}`)
    const errors = (error as { errors?: unknown[] }).errors
    if (Array.isArray(errors)) {
      for (const e of errors) console.log('  ', typeof e === 'object' && e !== null ? JSON.stringify(e).slice(0, 500) : String(e))
    }
    console.log('  ', String(error).slice(0, 800))
  }
}

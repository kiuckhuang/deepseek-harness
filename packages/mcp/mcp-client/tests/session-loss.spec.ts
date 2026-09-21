/** Session-loss classification across both MCP SDK error generations. */
import { describe, expect, it } from 'vitest'
import { isSessionLostError } from '../src/tools.ts'

describe('isSessionLostError', () => {
  it('classifies a client 2.x SdkHttpError session loss (status field)', () => {
    expect(isSessionLostError({
      name: 'SdkHttpError',
      code: 'CLIENT_HTTP_NOT_IMPLEMENTED',
      status: 404,
      message: 'Error POSTing to endpoint: {"error": "Session not found or expired"}',
    })).toBe(true)
  })

  it('classifies a legacy sdk StreamableHTTPError session loss (numeric code)', () => {
    expect(isSessionLostError({
      name: 'StreamableHTTPError',
      code: 404,
      message: 'Streamable HTTP error: Error POSTing to endpoint: {"error": "Session not found"}',
    })).toBe(true)
  })

  it('accepts 410 in either field', () => {
    expect(isSessionLostError({ code: 410, message: 'session terminated' })).toBe(true)
    expect(isSessionLostError({ status: 410, message: 'session terminated' })).toBe(true)
  })

  it('rejects a 404 whose message names no session loss', () => {
    expect(isSessionLostError({
      name: 'SdkHttpError',
      code: 'CLIENT_HTTP_NOT_IMPLEMENTED',
      status: 404,
      message: 'Error POSTing to endpoint: Cannot POST /wrong-path',
    })).toBe(false)
  })

  it('rejects other HTTP statuses and connection failures', () => {
    expect(isSessionLostError({ status: 500, message: 'Error POSTing to endpoint: boom' })).toBe(false)
    expect(isSessionLostError({ code: 'ECONNREFUSED', message: 'connect ECONNREFUSED 127.0.0.1:9185' })).toBe(false)
    expect(isSessionLostError(null)).toBe(false)
    expect(isSessionLostError('session not found')).toBe(false)
  })
})

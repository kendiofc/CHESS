--!strict
-- RateLimiter: a token bucket per player. Each request takes a token; tokens
-- refill at `perSecond` up to `burst`. Pure, so tests can drive the clock.

local RateLimiter = {}
RateLimiter.__index = RateLimiter

export type RateLimiter = typeof(setmetatable(
	{} :: { burst: number, perSecond: number, tokens: number, refilledAt: number },
	RateLimiter
))

function RateLimiter.new(burst: number, perSecond: number, now: number): RateLimiter
	return setmetatable({ burst = burst, perSecond = perSecond, tokens = burst, refilledAt = now }, RateLimiter)
end

-- Takes one token. Returns false when the bucket is empty.
function RateLimiter.take(self: RateLimiter, now: number): boolean
	self.tokens = math.min(self.burst, self.tokens + math.max(0, now - self.refilledAt) * self.perSecond)
	self.refilledAt = now
	if self.tokens < 1 then
		return false
	end
	self.tokens -= 1
	return true
end

return RateLimiter

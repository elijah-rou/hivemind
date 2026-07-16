/// Ratio: numerator/denominator probability. Allows very low probabilities
/// like 1-in-10-million that u8 percentages can't express.
#[derive(Debug, Clone, Copy)]
pub struct Ratio {
    pub numerator: u32,
    pub denominator: u32,
}

impl Ratio {
    pub fn new(numerator: u32, denominator: u32) -> Self {
        Self {
            numerator,
            denominator,
        }
    }

    pub fn zero() -> Self {
        Self {
            numerator: 0,
            denominator: 1,
        }
    }

    pub fn from_percent(pct: u8) -> Self {
        Self {
            numerator: pct as u32,
            denominator: 100,
        }
    }

    pub fn is_zero(&self) -> bool {
        self.numerator == 0
    }
}

/// Xorshift64 PRNG. Identical algorithm to src/prng.zig in the
/// Zig control plane. Same seed produces identical sequence.
pub struct Prng {
    state: u64,
}

impl Prng {
    pub fn init(seed: u64) -> Self {
        Self {
            state: if seed == 0 { 1 } else { seed },
        }
    }

    pub fn next(&mut self) -> u64 {
        let mut x = self.state;
        x ^= x << 13;
        x ^= x >> 7;
        x ^= x << 17;
        self.state = x;
        x
    }

    pub fn bounded(&mut self, bound: u64) -> u64 {
        assert!(bound > 0);
        self.next() % bound
    }

    pub fn chance(&mut self, percent: u8) -> bool {
        self.bounded(100) < percent as u64
    }

    pub fn chance_ratio(&mut self, ratio: Ratio) -> bool {
        if ratio.numerator == 0 {
            return false;
        }
        if ratio.numerator >= ratio.denominator {
            return true;
        }
        self.bounded(ratio.denominator as u64) < ratio.numerator as u64
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn deterministic_sequence() {
        let mut a = Prng::init(42);
        let mut b = Prng::init(42);
        for _ in 0..1000 {
            assert_eq!(a.next(), b.next());
        }
    }

    #[test]
    fn zero_seed_becomes_one() {
        let mut p = Prng::init(0);
        assert_ne!(p.next(), 0);
    }

    #[test]
    fn bounded_within_range() {
        let mut p = Prng::init(123);
        for _ in 0..1000 {
            assert!(p.bounded(10) < 10);
        }
    }

    #[test]
    fn chance_boundary() {
        let mut p = Prng::init(99);
        // chance(0) should always be false
        for _ in 0..100 {
            assert!(!p.chance(0));
        }
        // chance(100) should always be true
        let mut p2 = Prng::init(99);
        for _ in 0..100 {
            assert!(p2.chance(100));
        }
    }
}

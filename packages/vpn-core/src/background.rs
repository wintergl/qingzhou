//! Desktop maintenance deadlines. System notifications wake the worker early;
//! fallback checks keep clients without a native observer working too.
use std::time::Duration;

#[derive(Default)]
pub struct RuntimeEnvironment {
    pub sleeping: bool,
    pub low_power: bool,
    pub network_events: bool,
}

impl RuntimeEnvironment {
    pub fn maintenance_interval(&self, active: bool, recovering: bool) -> Duration {
        Duration::from_secs(if self.sleeping || !active {
            60
        } else if recovering {
            1
        } else if self.low_power {
            15
        } else {
            5
        })
    }

    pub fn network_interval(&self, recovering: bool) -> Duration {
        Duration::from_secs(if recovering {
            1
        } else {
            match (self.network_events, self.low_power) {
                (true, true) => 60,
                (true, false) => 30,
                (false, true) => 15,
                (false, false) => 5,
            }
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn notifications_allow_slow_fallback_but_never_delay_recovery() {
        let mut policy = RuntimeEnvironment::default();
        assert_eq!(policy.network_interval(false), Duration::from_secs(5));
        policy.network_events = true;
        assert_eq!(policy.network_interval(false), Duration::from_secs(30));
        policy.low_power = true;
        assert_eq!(policy.network_interval(false), Duration::from_secs(60));
        assert_eq!(policy.network_interval(true), Duration::from_secs(1));
        assert_eq!(
            policy.maintenance_interval(true, true),
            Duration::from_secs(1)
        );
    }

    #[test]
    fn stopped_sleeping_and_low_power_work_has_no_fast_idle_loop() {
        let mut policy = RuntimeEnvironment::default();
        assert_eq!(
            policy.maintenance_interval(false, false),
            Duration::from_secs(60)
        );
        assert_eq!(
            policy.maintenance_interval(true, false),
            Duration::from_secs(5)
        );
        policy.low_power = true;
        assert_eq!(
            policy.maintenance_interval(true, false),
            Duration::from_secs(15)
        );
        policy.sleeping = true;
        assert_eq!(
            policy.maintenance_interval(true, true),
            Duration::from_secs(60)
        );
    }
}

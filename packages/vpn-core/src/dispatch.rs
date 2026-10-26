//! Bounded command scheduling. Stop overtakes queued work; requests superseded
//! by a stop are rejected rather than unexpectedly reconnecting afterwards.
use serde_json::Value;
use std::{
    collections::VecDeque,
    sync::{Condvar, Mutex},
};

#[derive(Default)]
pub struct Dispatch {
    state: Mutex<State>,
    ready: Condvar,
}
#[derive(Default)]
struct State {
    urgent: VecDeque<Value>,
    normal: VecDeque<Value>,
    closed: bool,
}
impl Dispatch {
    pub fn push(&self, request: Value) -> Result<Vec<Value>, Value> {
        let mut state = self.state.lock().unwrap();
        let stop = request["channel"] == "vpn:stop";
        if state.closed || (!stop && state.normal.len() >= 64) || (stop && state.urgent.len() >= 8)
        {
            return Err(request);
        }
        let cancelled = if stop {
            let mut cancelled = Vec::new();
            let mut environment = VecDeque::new();
            for queued in state.normal.drain(..) {
                if queued["channel"] == "native:runtime-environment" {
                    environment.push_back(queued);
                } else {
                    cancelled.push(queued);
                }
            }
            state.normal = environment;
            cancelled
        } else {
            Vec::new()
        };
        if stop {
            state.urgent.push_back(request);
        } else {
            state.normal.push_back(request);
        }
        self.ready.notify_one();
        Ok(cancelled)
    }
    pub fn pop(&self) -> Option<Value> {
        let mut state = self.state.lock().unwrap();
        loop {
            if let Some(request) = state
                .urgent
                .pop_front()
                .or_else(|| state.normal.pop_front())
            {
                return Some(request);
            }
            if state.closed {
                return None;
            }
            state = self.ready.wait(state).unwrap();
        }
    }
    pub fn close(&self) {
        self.state.lock().unwrap().closed = true;
        self.ready.notify_all();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    #[test]
    fn stop_supersedes_queued_start_and_keeps_new_intent_ordered() {
        let queue = Dispatch::default();
        queue.push(json!({"channel":"vpn:start"})).unwrap();
        assert_eq!(queue.push(json!({"channel":"vpn:stop"})).unwrap().len(), 1);
        queue.push(json!({"channel":"vpn:start"})).unwrap();
        assert_eq!(queue.pop().unwrap()["channel"], "vpn:stop");
        assert_eq!(queue.pop().unwrap()["channel"], "vpn:start");
        queue.close();
        assert!(queue.pop().is_none());
    }
    #[test]
    fn full_queue_does_not_block_stop_or_input_reader() {
        let queue = Dispatch::default();
        for _ in 0..64 {
            queue.push(json!({"channel":"nodes:test"})).unwrap();
        }
        assert!(queue.push(json!({"channel":"nodes:test"})).is_err());
        assert_eq!(queue.push(json!({"channel":"vpn:stop"})).unwrap().len(), 64);
        assert_eq!(queue.pop().unwrap()["channel"], "vpn:stop");
    }
}

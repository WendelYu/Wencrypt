//! Jianguoyun free-plan traffic policy for the future WebDAV transport.
//! The transport must atomically persist reservations before sending requests.
use std::collections::VecDeque;

pub const ACCOUNT_REQUESTS_PER_HALF_HOUR: u32 = 600;
pub const APP_UPLOAD_BYTES_PER_MONTH: u64 = 300_000_000;
pub const APP_DOWNLOAD_BYTES_PER_MONTH: u64 = 900_000_000;
pub const DEVICE_REQUESTS_PER_HALF_HOUR: usize = 90;
pub const REQUEST_WINDOW_SECONDS: u64 = 30 * 60;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BudgetError {
    ClockWentBackwards,
    RequestLimit,
    UploadLimit,
    DownloadLimit,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct DeviceAllocation {
    pub upload_bytes: u64,
    pub download_bytes: u64,
}

impl DeviceAllocation {
    /// Three equal shares. Device registration must assign each share at most once.
    pub const DEFAULT_SLOT: Self = Self {
        upload_bytes: APP_UPLOAD_BYTES_PER_MONTH / 3,
        download_bytes: APP_DOWNLOAD_BYTES_PER_MONTH / 3,
    };
}

#[derive(Debug, Default)]
pub struct TrafficLedger {
    request_times: VecDeque<u64>,
    uploaded: u64,
    downloaded: u64,
    last_clock: Option<u64>,
}

impl TrafficLedger {
    /// Reserve full send/receive ceilings for one HTTP attempt, including retries.
    /// Calls within one accounting period must use a single persisted ledger.
    pub fn reserve(
        &mut self,
        allocation: DeviceAllocation,
        now_seconds: u64,
        upload_bytes: u64,
        download_ceiling: u64,
    ) -> Result<(), BudgetError> {
        if self.last_clock.is_some_and(|last| now_seconds < last) {
            return Err(BudgetError::ClockWentBackwards);
        }
        while self
            .request_times
            .front()
            .is_some_and(|then| now_seconds - then >= REQUEST_WINDOW_SECONDS)
        {
            self.request_times.pop_front();
        }
        if self.request_times.len() >= DEVICE_REQUESTS_PER_HALF_HOUR {
            return Err(BudgetError::RequestLimit);
        }
        let uploaded = self
            .uploaded
            .checked_add(upload_bytes)
            .filter(|bytes| *bytes <= allocation.upload_bytes)
            .ok_or(BudgetError::UploadLimit)?;
        let downloaded = self
            .downloaded
            .checked_add(download_ceiling)
            .filter(|bytes| *bytes <= allocation.download_bytes)
            .ok_or(BudgetError::DownloadLimit)?;

        self.uploaded = uploaded;
        self.downloaded = downloaded;
        self.last_clock = Some(now_seconds);
        self.request_times.push_back(now_seconds);
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn request_window_and_clock_rollback() {
        let mut ledger = TrafficLedger::default();
        let slot = DeviceAllocation::DEFAULT_SLOT;
        for _ in 0..DEVICE_REQUESTS_PER_HALF_HOUR {
            ledger.reserve(slot, 100, 0, 0).unwrap();
        }
        assert_eq!(
            ledger.reserve(slot, 99, 0, 0),
            Err(BudgetError::ClockWentBackwards)
        );
        assert_eq!(
            ledger.reserve(slot, 1899, 0, 0),
            Err(BudgetError::RequestLimit)
        );
        ledger.reserve(slot, 1900, 0, 0).unwrap();
    }

    #[test]
    fn byte_limit_rejection_does_not_spend_other_direction() {
        let mut ledger = TrafficLedger::default();
        let slot = DeviceAllocation {
            upload_bytes: 12,
            download_bytes: 20,
        };
        ledger.reserve(slot, 1, 10, 15).unwrap();
        assert_eq!(ledger.reserve(slot, 2, 6, 6), Err(BudgetError::UploadLimit));
        assert_eq!(
            ledger.reserve(slot, 2, 2, 6),
            Err(BudgetError::DownloadLimit)
        );
        ledger.reserve(slot, 2, 2, 5).unwrap();
        assert_eq!(
            ledger.reserve(slot, 3, 0, 1),
            Err(BudgetError::DownloadLimit)
        );
    }
}

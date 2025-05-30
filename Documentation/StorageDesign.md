**This setup ensures robust, reliable, and high-performing storage for a single TAP-paas production node - used for home and SMB worksloads.



| **Application/Service**                   | **Enterprise SSD Mirror** | **SSD Mirror** | **NVMe** | **HDD (1TB)** | **Min/Recommended Size** | **Rationale & Hardware Recommendation**                                                                                         |
|-------------------------------------------|:------------------------:|:--------------:|:--------:|:-------------:|:-----------------------:|-------------------------------------------------------------------------------------------------------|
| Proxmox Boot/System                       |           1              |      2         |          |               | 32GB / 120–240GB        | Enterprise SSDs are robust for OS boot; SSD mirror is fallback. <br>**Hardware:** Intel S3500/S3610 240GB or Samsung 870 EVO 250GB. |
| OPNsense Firewall                         |           1              |      2         |          |               | 32GB / 120–240GB        | Mission-critical; enterprise SSDs for isolation and reliability, SSD mirror if needed. Same hardware as above.                    |
| Nextcloud Data Directory                  |           2              |      1         |          |               | 500GB / 2–4TB           | User files need redundancy; SSD mirror is robust and fast.<br>**Hardware:** Samsung 870 EVO 2–4TB or Crucial MX500 2–4TB.         |
| Nextcloud Database                        |                          |      1         |    2     |               | 32GB / 500GB            | DB is critical; SSD mirror gives redundancy.<br>NVMe is faster but lacks redundancy—only if well-backed-up.<br>**NVMe:** Samsung 970 Pro/WD SN850X 500GB–1TB. |
| OnlyOffice (App & Data)                   |           2              |      1         |          |               | 32GB / 500GB            | Collaborative app benefits from redundancy and fast storage.<br>Same SSD hardware as above.                                        |
| Nextcloud Talk/Survey                     |           2              |      1         |          |               | 32GB / 500GB            | Core services; prioritize reliability and uptime.<br>Same SSD hardware as above.                                                  |
| Headscale                                 |           2              |      1         |          |               | 32GB / 120GB            | Lightweight but important; mirror gives reliability.                                                                              |
| Home Assistant                            |           2              |      1         |          |               | 32GB / 120GB            | Automation needs to be robust; SSD mirror is reliable and performant.                                                             |
| Pangolin                                  |           2              |      1         |          |               | 32GB / 120GB            | Security gateway; uptime and resilience are key.                                                                                  |
| High-IOPS DB/Cache/Temp VM                |                          |      2         |    1     |               | 32GB / 500GB            | Use NVMe for non-critical, performance-sensitive tasks.<br>**NVMe:** Samsung 970 Pro/WD SN850X 500GB–1TB.                         |
| Temporary/Scratch Data                    |                          |      2         |    1     |               | 32GB / 500GB            | NVMe is ideal for fast, restorable, non-critical workloads.                                                                       |
| Backups/Snapshots                         |                          |      2         |          |      1        | 500GB / 1TB             | HDD is suitable for cold storage, backups, and archives; SSD mirror if speed is needed.<br>**HDD:** WD Red/Seagate IronWolf 1TB.  |
| Archive/Logs                              |                          |      2         |          |      1        | 32GB / 1TB              | HDD is cost-effective for infrequent-access data; SSD mirror if logs are critical.                                                |
| Git (Automation Platform)                 |           2              |      1         |    2     |               | 32GB / 120GB            | Source code and config are valuable; mirror provides redundancy. NVMe for fast CI/CD if needed.                                   |
| OpenTofu (Open Source)                    |           2              |      1         |    2     |               | 32GB / 120GB            | State files/configs are important; mirror for safety. NVMe if running frequent, fast CI/CD jobs.                                  |
| Ansible                                   |           2              |      1         |    2     |               | 32GB / 120GB            | Playbooks/inventory are valuable; mirror for safety, NVMe for fast automation if needed.                                          |
| Proxmox Backup Server (PBS) OS & Metadata |           2              |      1         |          |               | 32GB / 120GB            | Redundant, reliable, and fast storage for backup server OS and metadata.<br>Same SSD hardware as above.                           |
| PBS Backup Datastore                      |                          |   1 or 2       |          |   1 or 2      | 500GB / 2–4TB (SSD) <br> 500GB / 1TB (HDD) | Use SSD mirror for fast/recent backups; HDD for larger/long-term/archival backups.                                                |
| SearxNG                                   |           2              |      1         |          |               | 32GB / 120GB            | Lightweight, but benefits from redundancy and fast access; SSD mirror is robust and sufficient.                                   |

---

### **Legend**
- **1** = Best option (preferred location)
- **2** = Second-best option (fallback if best is unavailable)
- Empty = Not recommended for this service

---

### **Minimum / Recommended Pool Sizes & Hardware Selection**

- **Enterprise SSD Mirror:**  
  - *Minimum:* 32GB per disk (OS/boot or small critical VMs)  
  - *Recommended:* 120–240GB per disk (gives headroom for logs, updates, extra VMs)  
  - *Hardware:* Intel S3500/S3610 240GB, Samsung 870 EVO 250GB, Crucial MX500 250GB

- **SSD Mirror:**  
  - *Minimum:* 120GB per disk (small setups), 500GB per disk for user data  
  - *Recommended:* 2–4TB per disk (for user data, VMs, containers, backups)  
  - *Hardware:* Samsung 870 EVO 2–4TB, Crucial MX500 2–4TB

- **NVMe:**  
  - *Minimum:* 120GB (test/lab), 500GB for fast VMs/containers  
  - *Recommended:* 500GB–1TB (for high-IOPS workloads, scratch, or CI/CD)  
  - *Hardware:* Samsung 970 Pro, WD SN850X, Crucial P5 Plus

- **HDD:**  
  - *Minimum:* 120GB (test), 500GB for basic backup  
  - *Recommended:* 1TB or more (for snapshots, archival, long-term backups)  
  - *Hardware:* WD Red 1TB, Seagate IronWolf 1TB

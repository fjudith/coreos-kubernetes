```bash
sudo mv /home/core/format-home-core-data-ceph-osd.service /etc/systemd/system/
sudo mv /home/core/home-core-data-ceph-osd-ceph-301.mount /etc/systemd/system/home-core-data-ceph-osd-ceph\\x2d301.mount
sudo mv /home/core/home-core-data-ceph-osd-ceph-302.mount /etc/systemd/system/home-core-data-ceph-osd-ceph\\x2d302.mount

sudo systemctl enable format-home-core-data-ceph-osd.service
sudo systemctl enable $(systemd-escape -p --suffix=mount /home/core/data/ceph/osd/ceph-301)
sudo systemctl enable $(systemd-escape -p --suffix=mount /home/core/data/ceph/osd/ceph-302)
```
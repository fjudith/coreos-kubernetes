```bash
sudo mv /home/core/format-home-core-data-ceph-osd.service
sudo mv /home/core/home-core-data-ceph-osd-ceph-201.mount /etc/systemd/system/home-core-data-ceph-osd-ceph\\x2d201.mount
sudo mv /home/core/home-core-data-ceph-osd-ceph-202.mount /etc/systemd/system/home-core-data-ceph-osd-ceph\\x2d202.mount

sudo systemctl enable format-home-core-data-ceph-osd.service
sudo systemctl enable $(systemd-escape -p --suffix=mount /home/core/data/ceph/osd/ceph-201)
sudo systemctl enable $(systemd-escape -p --suffix=mount /home/core/data/ceph/osd/ceph-202)
```
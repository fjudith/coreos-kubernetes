```bash
scp -i ~/.ssh/k8s-vsphere_id_rsa -o StrictHostKeyChecking=no  ./storage-host1/* core@192.168.251.201:/home/core/
```

```bash
sudo mv /home/core/format-home-core-data-ceph-osd.service /etc/systemd/system/
sudo mv /home/core/home-core-data-ceph-osd-ceph-101.mount /etc/systemd/system/home-core-data-ceph-osd-ceph\\x2d101.mount
sudo mv /home/core/home-core-data-ceph-osd-ceph-102.mount /etc/systemd/system/home-core-data-ceph-osd-ceph\\x2d102.mount

sudo systemctl enable format-home-core-data-ceph-osd.service
sudo systemctl enable $(systemd-escape -p --suffix=mount /home/core/data/ceph/osd/ceph-101)
sudo systemctl enable $(systemd-escape -p --suffix=mount /home/core/data/ceph/osd/ceph-102)
```
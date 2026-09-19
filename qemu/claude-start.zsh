#!/usr/bin/env zsh

# share directories via virtiofsd
pgrep -f "/usr/lib/virtiofsd --socket-path=/tmp/virtiofs-claude-share" ||
    /usr/lib/virtiofsd --socket-path=/tmp/virtiofs-claude-share --shared-dir=claude-share --cache=never --log-level off &

# slirp, --no-map-gw prevents guest from reaching host over gateway
passt -t 2221 --no-map-gw --vhost-user --socket /tmp/passt-claude --quiet

qemu-system-x86_64 -enable-kvm -smp 8 \
    -cpu host \
    -object memory-backend-memfd,id=mem,size=20G,share=on \
    -machine memory-backend=mem \
    -device virtio-balloon \
    -drive file=claude.qcow2,if=virtio \
    -chardev socket,id=chr0,path=/tmp/passt-claude \
    -netdev vhost-user,id=net0,chardev=chr0 \
    -device virtio-net-pci,netdev=net0 \
    -chardev socket,id=char1,path=/tmp/virtiofs-claude-share \
    -device vhost-user-fs-pci,queue-size=1024,chardev=char1,tag=share \
    -daemonize \
    -display none

until ssh -i =(pass open; pass qemu-claude-host3-ssh-key) -p 2221 user@127.0.0.1 'exit'; do sleep 1; done
ssh -p 2221 user@127.0.0.1 -i =(pass open; pass qemu-claude-host3-ssh-key)

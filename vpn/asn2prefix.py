#!/usr/bin/env python2
# -*- coding: utf-8 -*-
"""
Fetch an ASN's announced prefixes, collapse them, and spit them out
as JSON (default), bash-style arrays, or a plain list.

examples:
  ./asn2prefix.py 15169                 # JSON, good for jq
  ./asn2prefix.py AS714 --bash          # two shell arrays: ipv4[], ipv6[]
  ./asn2prefix.py 714 --plain ipv6      # newline-separated IPv6 only
"""

from __future__ import print_function
import sys, json, urllib2, argparse

try:
    import ipaddress          # back-port for Py-2
except ImportError:
    sys.stderr.write('Missing module "ipaddress". See previous message for options.\n')
    sys.exit(1)

API = 'https://api.bgpview.io/asn/{}/prefixes'


def fetch_prefixes(asn):
    data = json.load(urllib2.urlopen(API.format(asn)))['data']
    v4 = [p['prefix'] for p in data['ipv4_prefixes']]
    v6 = [p['prefix'] for p in data['ipv6_prefixes']]
    return v4, v6


def collapse(lst):
    nets = [ipaddress.ip_network(p.decode('ascii'), strict=False) for p in lst]
    return [str(n) for n in ipaddress.collapse_addresses(sorted(nets))]


def asn_num(raw):
    raw = raw.upper().lstrip('AS')
    if not raw.isdigit():
        raise argparse.ArgumentTypeError('ASN must be numeric or start with AS')
    return int(raw)


def parse_args():
    p = argparse.ArgumentParser(add_help=False)
    p.add_argument('asn', type=asn_num)
    out = p.add_mutually_exclusive_group()
    out.add_argument('--bash', action='store_true',
                     help='output bash array literals')
    out.add_argument('--plain', choices=['ipv4', 'ipv6', 'both'],
                     help='newline list (ipv4 / ipv6 / both)')
    p.add_argument('-h', '--help', action='help',
                   help='show this help and exit')
    return p.parse_args()


def main():
    opt = parse_args()
    v4_raw, v6_raw = fetch_prefixes(opt.asn)
    v4 = collapse(v4_raw)
    v6 = collapse(v6_raw)

    if opt.bash:
        print('declare -a ipv4=(' + ' '.join(map(repr, v4)) + ')')
        print('declare -a ipv6=(' + ' '.join(map(repr, v6)) + ')')
        return

    if opt.plain:
        if opt.plain in ('ipv4', 'both'):
            print('\n'.join(v4))
        if opt.plain in ('ipv6', 'both'):
            print('\n'.join(v6))
        return

    # default: JSON
    out = {
        'ipv4': v4,
        'ipv6': v6,
        'stats': {
            'raw_v4': len(v4_raw),
            'raw_v6': len(v6_raw),
            'collapsed_v4': len(v4),
            'collapsed_v6': len(v6)
        }
    }
    print(json.dumps(out, separators=(',', ':')))


if __name__ == '__main__':
    main()

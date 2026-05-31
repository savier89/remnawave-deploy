#!/usr/bin/env python3
with open('deploy.sh.broken') as f:
    c = f.read()

# Fix truncations
c = c.replace('...nssl', 'openssl')
c = c.replace('POS...w', 'POSTGRES_PASSWORD=*** c = c.replace('POS...g', 'POSTGRES_PASSWORD=*** c = c.replace('WEB...h', 'WEBHOOK_SECRET_HEADER=*** # Fix DATABASE_URL regex: ***@]* -> [^@]*
c = c.replace('***@]*', '[^' + chr(64) + ']*')

# Fix indentation
lines = c.split('\n')
for i in range(len(lines)):
    if lines[i].startswith('     ') and not lines[i].startswith('      '):
        lines[i] = '    ' + lines[i][5:]
    if lines[i].startswith('       ') and not lines[i].startswith('        '):
        lines[i] = '        ' + lines[i][7:]
c = '\n'.join(lines)

with open('deploy.sh', 'w') as f:
    f.write(c)

print('Done')

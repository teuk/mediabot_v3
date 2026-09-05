'use strict';

function qIdent(identifier) {
  if (!/^[A-Za-z0-9_]+$/.test(identifier)) {
    throw new Error(`Unsafe SQL identifier: ${identifier}`);
  }
  return '`' + identifier + '`';
}

module.exports = {
  qIdent
};

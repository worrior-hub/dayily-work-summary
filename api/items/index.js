// GET /api/items  : 전체 목록
// POST /api/items : 새 자료 등록
const s = require('../_store');

module.exports = async (req, res) => {
  if (!s.checkAccess(req, res)) return;
  try {
    if (req.method === 'GET') return s.sendJson(res, 200, await s.listItems());
    if (req.method === 'POST') {
      const item = s.toItem(s.readBody(req), null);
      await s.saveItem(item);
      return s.sendJson(res, 201, item);
    }
    s.sendJson(res, 404, { error: 'not found' });
  } catch (err) {
    s.sendError(res, err);
  }
};

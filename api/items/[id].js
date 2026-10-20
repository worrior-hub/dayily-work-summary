// PUT /api/items/{id}    : 자료 수정
// DELETE /api/items/{id} : 자료 삭제
const s = require('../_store');

module.exports = async (req, res) => {
  if (!s.checkAccess(req, res)) return;
  try {
    const id = String(req.query.id || '');
    if (!/^[0-9a-zA-Z]+$/.test(id)) return s.sendJson(res, 404, { error: 'not found' });
    const existing = await s.getItem(id);
    if (!existing) return s.sendJson(res, 404, { error: 'not found' });
    if (req.method === 'PUT') {
      const item = s.toItem(s.readBody(req), existing);
      await s.saveItem(item);
      return s.sendJson(res, 200, item);
    }
    if (req.method === 'DELETE') {
      await s.removeItem(id);
      return s.sendEmpty(res, 204);
    }
    s.sendJson(res, 404, { error: 'not found' });
  } catch (err) {
    s.sendError(res, err);
  }
};

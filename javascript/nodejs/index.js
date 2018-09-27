/*
Specification on project:
Platform: NodeJS, Docker
Framework: ExpressJS
Database: MongoDB, memcached, Redis

Tests: Unit tests, Integration tests
Test tools: Chai, Mocha, Supertest, Istanbul

Documentation: apidoc

Clean code: ESLint

Additional libraries: co, aws-sdk, docxtemplater, ejs
*/

/*
      Workflow controller
*/

const workflowValidation = joi.object().keys({
  name: joi.string().min(3).max(40).required(),
  shortDescription: joi.string().allow(''),
  editors: joi.array().sparse(),
  organisation: joi.objectId().default(null),
  status: joi.string(),
  firstAction: joi.object(),
  map: joi.object().default({})
});

const createWorkflow = (req, res, next) => {
  co(function* () {

    const validationError = joi.validate(req.body, workflowValidation).error;

    if (validationError) {
      return res.status(400).send({ message: validationError.details.shift().message });
    }

    const workflow = yield workflowService.create({
      ...req.body,
      organisation: req.user.organisation
    });

    res.status(200).send(workflow);
  }).catch(next);
};

const getWorkflowById = (req, res, next) => {
  co(function* () {
    const id = req.params.id;

    if (!mongoose.Types.ObjectId.isValid(id)) {
      return res.status(400).send({ message: ERROR_MESSAGE.NOT_VALID_ID });
    }
    const checkWorkflow = yield workflowService.findById(id);
    if (!checkWorkflow) {
      return res.status(404).send({ message: ERROR_MESSAGE.NOT_FOUND });
    }
    if (!checkWorkflow.organisation.equals(req.user.organisation)) {
      return res.status(403).send({ message: ERROR_MESSAGE.ERROR_PER_DENIED });
    }

    const workflow = yield workflowService.findByIdWithActions(id);
    if (!workflow || !workflow.length) {
      return res.status(404).send({ message: ERROR_MESSAGE.NOT_FOUND });
    }

    res.status(200).send(workflow);
  }).catch(next);
};

/*
      Access handler service
*/

const isUserBlocked = (email, organisationId) => {
  return co(function* () {
    let block = false;
    const userLogins = yield memcache.get(`${email}_${organisationId}`);
    if(userLogins && userLogins.value >= config.accessParams.maximumGuesses){
      yield memcache.touch(`${email}_${organisationId}`, config.accessParams.timePeriod);
      block = true;
    }
    return block;
  });
};

/*
      Workflow Sessions services
*/

this.model.aggregate([
  {
    $match: {
      workflowId: mongoose.Types.ObjectId(workflowId),
      deleted: false
    }
  },
  {
    $addFields: {
      'actions': {
        $filter: {
          input: '$actions',
          as: 'action',
          cond: {
            $and: [{ $eq: ['$$action.actionType', 'Form'] }, { $ne: ['$$action.data', null] }]
          }
        }
      }
    }
  },
  { $project: { 'actions.data': 1 } },

  { $match: { 'actions.0': { $exists: 1 } } }
]);


/*
      Constants roleTypeConstants.js
*/

'use strict';

module.exports = Object.freeze({
  USER: 'USER',
  ADMIN: 'ADMIN',
  PUBLIC: 'PUBLIC',
  MANAGER: 'MANAGER',
  PUBLIC_USER: 'PUBLIC_USER'
});

/*
      Workflow model
*/

const Schema = new mongoose.Schema({
  name: {
    type: String,
    required: true,
    minlength: 3,
    trim: true
  },
  shortDescription: {
    type: String,
    required: false,
    trim: true,
    maxlength: 145
  },
  status: {
    type: String,
    enum: ['draft', 'published', 'archived'],
    default: 'draft'
  },
  organisation: {
    type: ObjectId,
    ref: 'Organisation',
    required: true
  },
  createdAt: {
    type: Number,
    default: Date.now()
  },
  parentId: {
    type: ObjectId,
    required: false
  },
  workflowStats: {
    started: { type: Number, default: 0 },
    completed: { type: Number, default: 0 },
    avgExecution: { type: Number, default: null },
  }
}, {
  strict: true
});

Schema.plugin(mongooseDelete, { overrideMethods: true, deletedAt: true });

Schema.methods.incrementVersion = async function() {
  return await this.update({ $inc: { version: 1 } }, { new: true });
};

Schema.methods.isArchived = function() {
  return this.status === CONSTANTS.WORKFLOW_STATUSES.ARCHIVED;
};


/*
      Workflow router http://localhost:4000/workflow/.....
*/


router.get('/', roleService.can([ROLE.ADMIN, ROLE.MANAGER, ROLE.USER]), workflowController.getWorkflows);
router.get('/:id', roleService.can([ROLE.ADMIN, ROLE.MANAGER, ROLE.USER]), workflowController.getWorkflowById);
router.post('/', roleService.can([ROLE.ADMIN, ROLE.MANAGER]), logging.logs, workflowController.createWorkflow);
router.delete('/:id', roleService.can([ROLE.ADMIN, ROLE.MANAGER]), logging.logs, workflowController.deleteWorkflow);

/*
      Small example Unit test
*/

const AuttoLang = require('../../src/services/auttoLang');

it('should return IS THEN branch', () => {
  const preparedContext = { Age: 21 };
  const text = 'IF [Age] IS 21 THEN ##21-Branch## ELSE ##NOT-21-branch##';

  const result = AuttoLang.execute(preparedContext, text);

  expect(result.result).to.be.equal('21-Branch');
});

/*
      Basic workflow tests
*/

'use strict';

describe('Workflow api tests', () => {
  let organisationId,
    managerToken,
    workflowId,
    managerId;

  beforeEach(co.wrap(function* beforeEach () {
    organisationId = (yield mongoose.connection.collection('organisations').insert({
      name: 'Test organisation',
      email: 'organisation123@mail.com',
      domain: 'super-domain',
      active: true
    })).insertedIds[0];

    managerId = (yield mongoose.connection.collection('users').insert({
      name: 'Manager user',
      email: 'manager-user@mail.com',
      password: 'somepassword',
      role: 'MANAGER',
      organisation: organisationId,
      active: true
    })).insertedIds[0];

    managerToken = (yield mongoose.connection.collection('accesstokens').insert({
      _id: '591ea63a94743d2e6c334304',
      user: managerId,
      createdAt: Date.now(),
      ttl: 60 * 60 * 24 * 15
    })).insertedIds[0];

    const workflowData = JSON.parse(JSON.stringify(require('../fixture/workflow1.json')));
    workflowId = (yield mongoose.connection.model('Workflow').create(workflowData))._id;
  }));

  afterEach(co.wrap(function* beforeEach () {
    yield mongoose.connection.collection('workflows').remove({});
    yield mongoose.connection.collection('users').remove({});
    yield mongoose.connection.collection('organisations').remove({});
    yield mongoose.connection.collection('accesstokens').remove({});
  }));

  it('should return 200 and workflow by id with actions', co.wrap(function* () {
    const res = yield supertest.agent(app)
      .get(`/workflow/${workflowId}`)
      .set('x-auth-token', managerToken)
      .expect(200);

    expect(res.body).to.be.instanceof(Object);
    expect(res.body).to.have.property('_id');
    expect(res.body).to.have.property('name');
    // ...........Check another fields.........//////
    expect(res.body.workflowStats).to.have.property('avgExecution', null);

    const action = res.body.actions[0];
    expect(action).to.have.property('_id');
    // ...........Check another fields.........//////
  }));

  it('should return 200 and list of archived workflows', co.wrap(function* () {
    yield  mongoose.connection.collection('workflows').update({ _id: workflowId }, { $set: { status: 'archived' } });

    const res = yield supertest.agent(app)
      .get('/workflow?status=archived')
      .set('x-auth-token', managerToken)
      .expect(200);

    expect(res.body[0]).to.have.property('status', 'archived');
  }));

  it('should return 200 and empty list of workflows', co.wrap(function* () {
    yield mongoose.connection.collection('workflows').remove({});

    const res = yield supertest.agent(app)
      .get('/workflow')
      .set('x-auth-token', managerToken)
      .expect(200);

    expect(res.body).to.be.instanceof(Array);
    expect(res.body).to.be.lengthOf(0);
  }));

  it('should return 401 for unauthorized user', co.wrap(function* () {
    yield supertest.agent(app)
      .get('/workflow')
      .expect(401);
  }));


  it('should return 200 and create workflow', co.wrap(function* () {
    const workflowData = {
      name: 'testWorklow2',
      shortDescription: 'Short descriptionShort',
      organisation: '59196f8ac6e3d6243048b5f1'
    };

    const res = yield supertest.agent(app)
      .post('/workflow')
      .send(workflowData)
      .set('x-auth-token', managerToken)
      .expect(200);

    expect(res.body).to.be.instanceof(Object);
    expect(res.body).to.have.property('_id');
    expect(res.body).to.have.property('name', workflowData.name);
  }));


  it('should return 200 and delete workflow', co.wrap(function* () {
    yield supertest.agent(app)
      .delete(`/workflow/${workflowId}`)
      .set('x-auth-token', managerToken)
      .expect(200);

    const workflowFound = yield mongoose.connection.collection('workflows').findOne({ _id: workflowId });
    expect(workflowFound).to.be.not.empty;
    expect(workflowFound).to.have.property('deleted', true);
  }));
});

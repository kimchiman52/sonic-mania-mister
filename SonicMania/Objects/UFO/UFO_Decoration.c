// ---------------------------------------------------------------------
// RSDK Project: Sonic Mania
// Object Description: UFO_Decoration Object
// Object Author: Christian Whitehead/Simon Thomley/Hunter Bridges
// Decompiled by: Rubberduckycooly & RMGRich
// ---------------------------------------------------------------------

#include "Game.h"

ObjectUFO_Decoration *UFO_Decoration;

#if defined(RSDK_USE_MISTER)
#include <stdint.h>
#include <string.h>

extern void Scene3D_SetDrawSource(uint32_t source);
extern void Scene3D_EnableCachedModelFaceColors(uint16_t modelID);
extern void Scene3D_EnableSkipModelNormals(uint16_t modelID);
extern int32_t Scene3D_GetModelBounds(uint16_t modelID,
                                      int32_t *minX, int32_t *minY, int32_t *minZ,
                                      int32_t *maxX, int32_t *maxY, int32_t *maxZ);
extern int32_t Scene3D_ModelFitsScene(uint16_t sceneID, uint16_t modelID);

#define UFO_DECORATION_MAX_ZDEPTH   0x100000
#define UFO_DECORATION_MIN_DRAW_SCALE 0x100
#define UFO_DECORATION_BOUNDS_CULL_MARGIN 8
#define UFO_DECORATION_MIN_BOUNDS_PIXELS 3
#define UFO_SPECIAL_SCENE_VERT_LIMIT 0x4000
#define UFO_S3D_SOURCE_DECORATION   1

static bool32 s_dec_bounds_valid[8];
static int32_t s_dec_min_x[8], s_dec_min_y[8], s_dec_min_z[8];
static int32_t s_dec_max_x[8], s_dec_max_y[8], s_dec_max_z[8];

static void UFO_Decoration_FlushBatch(void)
{
    Scene3D_SetDrawSource(UFO_S3D_SOURCE_DECORATION);
    RSDK.Draw3DScene(UFO_Decoration->sceneIndex);
    RSDK.Prepare3DScene(UFO_Decoration->sceneIndex);
}

static bool32 UFO_Decoration_ProjectOriginVisible(EntityUFO_Decoration *self)
{
    if (self->zdepth < 0x100)
        return false;

    int32 x = self->position.x;
    int32 y = self->height;
    int32 z = self->position.y;
    Matrix *m = &UFO_Camera->matWorld;

    int32 depth = (int32)((m->values[0][3] << 8) + (m->values[0][2] * (z >> 8) & 0xFFFFFF00)
                          + (m->values[0][0] * (x >> 8) & 0xFFFFFF00) + (m->values[0][1] * (y >> 8) & 0xFFFFFF00))
                  / self->zdepth;

    return abs(depth) < 0x100;
}

static bool32 UFO_Decoration_ProjectBoundsVisible(EntityUFO_Decoration *self)
{
    if (self->type < 0 || self->type >= 8 || !s_dec_bounds_valid[self->type])
        return true;

    Matrix *m = &self->matWorld;
    int32 minScreenX = 0x7FFFFFFF;
    int32 minScreenY = 0x7FFFFFFF;
    int32 maxScreenX = -0x7FFFFFFF;
    int32 maxScreenY = -0x7FFFFFFF;

    for (int32 ix = 0; ix < 2; ++ix) {
        int32 x = ix ? s_dec_max_x[self->type] : s_dec_min_x[self->type];
        for (int32 iy = 0; iy < 2; ++iy) {
            int32 y = iy ? s_dec_max_y[self->type] : s_dec_min_y[self->type];
            for (int32 iz = 0; iz < 2; ++iz) {
                int32 z = iz ? s_dec_max_z[self->type] : s_dec_min_z[self->type];
                int32 vx = m->values[0][3] + (int32)(((int64_t)z * m->values[0][2]) >> 8)
                         + (int32)(((int64_t)x * m->values[0][0]) >> 8)
                         + (int32)(((int64_t)y * m->values[0][1]) >> 8);
                int32 vy = m->values[1][3] + (int32)(((int64_t)y * m->values[1][1]) >> 8)
                         + (int32)(((int64_t)z * m->values[1][2]) >> 8)
                         + (int32)(((int64_t)x * m->values[1][0]) >> 8);
                int32 vz = m->values[2][3] + (int32)(((int64_t)x * m->values[2][0]) >> 8)
                         + (int32)(((int64_t)z * m->values[2][2]) >> 8)
                         + (int32)(((int64_t)y * m->values[2][1]) >> 8);

                if (vz < 0x100)
                    return true;

                int32 sx = ScreenInfo->center.x + (int32)(((int64_t)vx << 8) / vz);
                int32 sy = ScreenInfo->center.y - (int32)(((int64_t)vy << 8) / vz);
                if (sx < minScreenX) minScreenX = sx;
                if (sy < minScreenY) minScreenY = sy;
                if (sx > maxScreenX) maxScreenX = sx;
                if (sy > maxScreenY) maxScreenY = sy;
            }
        }
    }

    int32 margin = UFO_DECORATION_BOUNDS_CULL_MARGIN;
    if (maxScreenX < ScreenInfo->clipBound_X1 - margin || minScreenX > ScreenInfo->clipBound_X2 + margin
        || maxScreenY < ScreenInfo->clipBound_Y1 - margin || minScreenY > ScreenInfo->clipBound_Y2 + margin)
        return false;

    return (maxScreenX - minScreenX) >= UFO_DECORATION_MIN_BOUNDS_PIXELS
        && (maxScreenY - minScreenY) >= UFO_DECORATION_MIN_BOUNDS_PIXELS;
}

static void UFO_Decoration_MultiplyAffine(Matrix *dst, Matrix *a, Matrix *b)
{
    Matrix out;

    for (int32 row = 0; row < 4; ++row) {
        int32 a0 = a->values[0][row];
        int32 a1 = a->values[1][row];
        int32 a2 = a->values[2][row];
        int32 a3 = a->values[3][row];

        for (int32 col = 0; col < 4; ++col) {
            out.values[col][row] = (a3 * b->values[col][3] >> 8) + (a2 * b->values[col][2] >> 8)
                                 + (a1 * b->values[col][1] >> 8) + (a0 * b->values[col][0] >> 8);
        }
    }

    memcpy(dst, &out, sizeof(out));
}

static void UFO_Decoration_SetMatrices(EntityUFO_Decoration *self)
{
    int32 sine   = RSDK.Sin1024(self->angle) >> 2;
    int32 cosine = RSDK.Cos1024(self->angle) >> 2;
    int32 scaleX = self->scale.x;
    int32 scaleY = self->size;

    Matrix local;
    memset(&local, 0, sizeof(local));
    local.values[0][0] = cosine * scaleX >> 8;
    local.values[2][0] = sine * scaleX >> 8;
    local.values[1][1] = scaleY;
    local.values[0][2] = -sine * scaleX >> 8;
    local.values[2][2] = cosine * scaleX >> 8;
    local.values[0][3] = self->position.x >> 8;
    local.values[1][3] = self->height >> 8;
    local.values[2][3] = self->position.y >> 8;
    local.values[3][3] = 0x100;

    Matrix normal;
    memset(&normal, 0, sizeof(normal));
    normal.values[0][0] = cosine;
    normal.values[2][0] = sine;
    normal.values[1][1] = 0x100;
    normal.values[0][2] = -sine;
    normal.values[2][2] = cosine;
    normal.values[3][3] = 0x100;

    UFO_Decoration_MultiplyAffine(&self->matWorld, &local, &UFO_Camera->matWorld);
    UFO_Decoration_MultiplyAffine(&self->matNormal, &normal, UFO_Camera->isSS7 ? &UFO_Camera->matTemp : &UFO_Camera->matView);
}
#endif

void UFO_Decoration_Update(void)
{
    RSDK_THIS(UFO_Decoration);

    if (RSDK.CheckOnScreen(self, NULL)) {
        self->scale.x += (self->size - self->scale.x) >> 3;
        self->active = ACTIVE_NORMAL;
    }
    else {
        self->scale.x = 0x000;
        self->active  = ACTIVE_BOUNDS;
    }

#if defined(RSDK_USE_MISTER)
    self->active = ACTIVE_NORMAL;
#endif

    if (self->type > UFO_DECOR_PILLAR2)
        RSDK.ProcessAnimation(&self->animator);
}

void UFO_Decoration_LateUpdate(void)
{
    RSDK_THIS(UFO_Decoration);

    int32 x = self->position.x;
    int32 y = self->height;
    int32 z = self->position.y;

    Matrix *m = &UFO_Camera->matWorld;

    self->zdepth = m->values[2][1] * (y >> 16) + m->values[2][2] * (z >> 16) + m->values[2][0] * (x >> 16) + m->values[2][3];

#if defined(RSDK_USE_MISTER)
    bool32 projectVisible = UFO_Decoration_ProjectOriginVisible(self);
    self->visible         = projectVisible && self->zdepth <= UFO_DECORATION_MAX_ZDEPTH;
#else
    int32 depth = 0;
    if (self->zdepth >= 0x4000) {
        depth = (int32)((m->values[0][3] << 8) + (m->values[0][2] * (z >> 8) & 0xFFFFFF00) + (m->values[0][0] * (x >> 8) & 0xFFFFFF00)
                        + (m->values[0][1] * (y >> 8) & 0xFFFFFF00))
                / self->zdepth;
        self->visible = abs(depth) < 0x100;
    }
    else {
        self->visible = false;
    }
#endif
}

void UFO_Decoration_StaticUpdate(void) {}

void UFO_Decoration_Draw(void)
{
    RSDK_THIS(UFO_Decoration);

#if defined(RSDK_USE_MISTER)
    bool32 drawDecoration = self->visible && self->scale.x >= UFO_DECORATION_MIN_DRAW_SCALE;
#else
    bool32 drawDecoration = self->zdepth >= 0x4000;
#endif

    if (drawDecoration) {
#if !defined(RSDK_USE_MISTER)
        RSDK.Prepare3DScene(UFO_Decoration->sceneIndex);
#endif

#if defined(RSDK_USE_MISTER)
        UFO_Decoration_SetMatrices(self);
#else
        RSDK.MatrixScaleXYZ(&self->matTransform, self->scale.x, self->size, self->scale.x);
        RSDK.MatrixTranslateXYZ(&self->matTransform, self->position.x, self->height, self->position.y, 0);

        RSDK.MatrixRotateY(&self->matNormal, self->angle);
        RSDK.MatrixMultiply(&self->matWorld, &self->matNormal, &self->matTransform);
        RSDK.MatrixMultiply(&self->matWorld, &self->matWorld, &UFO_Camera->matWorld);

        if (UFO_Camera->isSS7)
            RSDK.MatrixMultiply(&self->matNormal, &self->matNormal, &UFO_Camera->matTemp);
        else
            RSDK.MatrixMultiply(&self->matNormal, &self->matNormal, &UFO_Camera->matView);
#endif

        uint16 modelIndex = UFO_Decoration->modelIndices[self->type];

#if defined(RSDK_USE_MISTER)
        if (!UFO_Decoration_ProjectBoundsVisible(self))
            return;

        if (!Scene3D_ModelFitsScene(UFO_Decoration->sceneIndex, modelIndex))
            UFO_Decoration_FlushBatch();

        Scene3D_SetDrawSource(UFO_S3D_SOURCE_DECORATION);
#endif

        if (self->type <= UFO_DECOR_PILLAR2)
            RSDK.AddModelTo3DScene(modelIndex, UFO_Decoration->sceneIndex, UFO_Decoration->drawType, &self->matWorld,
                                   &self->matNormal, 0xFFFFFF);
        else
            RSDK.AddMeshFrameTo3DScene(modelIndex, UFO_Decoration->sceneIndex, &self->animator,
                                       UFO_Decoration->drawType, &self->matWorld, &self->matNormal, 0xFFFFFF);

#if !defined(RSDK_USE_MISTER)
        RSDK.Draw3DScene(UFO_Decoration->sceneIndex);
#endif
    }

}

void UFO_Decoration_Create(void *data)
{
    RSDK_THIS(UFO_Decoration);

    if (!SceneInfo->inEditor) {
        if (!self->size)
            self->size = 0x400;

#if defined(RSDK_USE_MISTER)
        self->visible       = false;
        self->drawGroup     = 4;
        self->active        = ACTIVE_NORMAL;
        self->updateRange.x = 0x4000000;
        self->updateRange.y = 0x4000000;
#else
        self->visible       = true;
        self->drawGroup     = 4;
        self->active        = ACTIVE_BOUNDS;
        self->updateRange.x = 0x4000000;
        self->updateRange.y = 0x4000000;
#endif

        if (self->type == UFO_DECOR_BIRD)
            self->height = 0x600000;

        RSDK.SetModelAnimation(UFO_Decoration->modelIndices[self->type], &self->animator, 96, 0, true, 0);
    }
}

void UFO_Decoration_StageLoad(void)
{
    UFO_Decoration->modelIndices[UFO_DECOR_TREE]    = RSDK.LoadMesh("Decoration/Tree.bin", SCOPE_STAGE);
    UFO_Decoration->modelIndices[UFO_DECOR_FLOWER1] = RSDK.LoadMesh("Decoration/Flower1.bin", SCOPE_STAGE);
    UFO_Decoration->modelIndices[UFO_DECOR_FLOWER2] = RSDK.LoadMesh("Decoration/Flower2.bin", SCOPE_STAGE);
    UFO_Decoration->modelIndices[UFO_DECOR_FLOWER3] = RSDK.LoadMesh("Decoration/Flower3.bin", SCOPE_STAGE);
    UFO_Decoration->modelIndices[UFO_DECOR_PILLAR1] = RSDK.LoadMesh("Decoration/Pillar1.bin", SCOPE_STAGE);
    UFO_Decoration->modelIndices[UFO_DECOR_PILLAR2] = RSDK.LoadMesh("Decoration/Pillar2.bin", SCOPE_STAGE);
    UFO_Decoration->modelIndices[UFO_DECOR_BIRD]    = RSDK.LoadMesh("Decoration/Bird.bin", SCOPE_STAGE);
    UFO_Decoration->modelIndices[UFO_DECOR_FISH]    = RSDK.LoadMesh("Decoration/Fish.bin", SCOPE_STAGE);

#if defined(RSDK_USE_MISTER)
    for (int32 i = 0; i < 8; ++i) {
        Scene3D_EnableCachedModelFaceColors(UFO_Decoration->modelIndices[i]);
        s_dec_bounds_valid[i] = Scene3D_GetModelBounds(UFO_Decoration->modelIndices[i],
                                                       &s_dec_min_x[i], &s_dec_min_y[i], &s_dec_min_z[i],
                                                       &s_dec_max_x[i], &s_dec_max_y[i], &s_dec_max_z[i]);
    }
    Scene3D_EnableSkipModelNormals(UFO_Decoration->modelIndices[UFO_DECOR_BIRD]);
#endif

    UFO_Decoration->sceneIndex = RSDK.Create3DScene("View:Special",
#if defined(RSDK_USE_MISTER)
                                                    UFO_SPECIAL_SCENE_VERT_LIMIT,
#else
                                                    4096,
#endif
                                                    SCOPE_STAGE);

    UFO_Decoration->drawType = S3D_SOLIDCOLOR_SHADED_SCREEN;
}

#if GAME_INCLUDE_EDITOR
void UFO_Decoration_EditorDraw(void) {}

void UFO_Decoration_EditorLoad(void)
{

    RSDK_ACTIVE_VAR(UFO_Decoration, type);
    RSDK_ENUM_VAR("Tree", UFO_DECOR_TREE);
    RSDK_ENUM_VAR("Flower 1", UFO_DECOR_FLOWER1);
    RSDK_ENUM_VAR("Flower 2", UFO_DECOR_FLOWER2);
    RSDK_ENUM_VAR("Flower 3", UFO_DECOR_FLOWER3);
    RSDK_ENUM_VAR("Pillar 1", UFO_DECOR_PILLAR1);
    RSDK_ENUM_VAR("Pillar 2", UFO_DECOR_PILLAR2);
    RSDK_ENUM_VAR("Bird", UFO_DECOR_BIRD);
    RSDK_ENUM_VAR("Fish", UFO_DECOR_FISH);
}
#endif

void UFO_Decoration_Serialize(void)
{
    RSDK_EDITABLE_VAR(UFO_Decoration, VAR_ENUM, type);
    RSDK_EDITABLE_VAR(UFO_Decoration, VAR_ENUM, angle);
    RSDK_EDITABLE_VAR(UFO_Decoration, VAR_ENUM, size);
}
